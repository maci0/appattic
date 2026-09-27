#include "embed.h"
#include "hostexec.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/stat.h>
#include <wasm.h>
#include <wasmtime.h>

typedef struct {
    char *buf;
    size_t len;
    int failed;
} Err;

static void fail_msg(Err *e, const char *msg) {
    if (e->failed) return;
    e->failed = 1;
    if (e->buf && e->len) {
        snprintf(e->buf, e->len, "%s", msg);
    }
}

static void fail_error(Err *e, const char *what, wasmtime_error_t *err) {
    wasm_name_t msg;
    wasmtime_error_message(err, &msg);
    if (!e->failed && e->buf && e->len) {
        snprintf(e->buf, e->len, "%s: %.*s", what, (int)msg.size, msg.data);
    }
    e->failed = 1;
    wasm_byte_vec_delete(&msg);
    wasmtime_error_delete(err);
}

static void fail_trap(Err *e, const char *what, wasm_trap_t *trap) {
    wasm_name_t msg;
    wasm_trap_message(trap, &msg);
    if (!e->failed && e->buf && e->len) {
        snprintf(e->buf, e->len, "%s: %.*s", what, (int)msg.size, msg.data);
    }
    e->failed = 1;
    wasm_byte_vec_delete(&msg);
    wasm_trap_delete(trap);
}

static unsigned char *read_file(const char *path, size_t *len, Err *e) {
    FILE *f = fopen(path, "rb");
    if (!f) {
        fail_msg(e, path);
        return NULL;
    }
    if (fseek(f, 0, SEEK_END) != 0) {
        fail_msg(e, "fseek");
        fclose(f);
        return NULL;
    }
    long n = ftell(f);
    if (n < 0) {
        fail_msg(e, "ftell");
        fclose(f);
        return NULL;
    }
    rewind(f);
    unsigned char *buf = malloc((size_t)n);
    if (!buf) {
        fail_msg(e, "oom reading wasm");
        fclose(f);
        return NULL;
    }
    if (fread(buf, 1, (size_t)n, f) != (size_t)n) {
        fail_msg(e, "fread");
        free(buf);
        fclose(f);
        return NULL;
    }
    fclose(f);
    *len = (size_t)n;
    return buf;
}

/* One engine and one compiled module per (path, size, mtime), reused across
   scans, on top of wasmtime's on-disk compilation cache. Compiling is the
   single biggest cost of a scan: re-JITting the core and all 27 plugins costs
   ~60 ms, and every scan in every process paid it (the CLI pays it once per
   invocation, the UI on launch and again on each scan). Slots are bounded, and
   are emptied between runs rather than while one may still hold them. */
#define MOD_CACHE_MAX 64
typedef struct {
    char *path;
    long size;
    long mtime_s;
    long mtime_ns;
    wasmtime_module_t *module;
} ModSlot;

static pthread_mutex_t g_mod_lock = PTHREAD_MUTEX_INITIALIZER;
static wasm_engine_t *g_engine;
static ModSlot g_mods[MOD_CACHE_MAX];
static int g_mod_count;

/* How many runs hold the engine right now. Compilation runs outside
   g_mod_lock on purpose, so the module cache alone cannot keep the engine
   alive: without this count, a shutdown on the teardown thread frees the
   engine and its modules under a scan that is still executing. */
static pthread_mutex_t g_life_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_life_idle_monotonic;
static pthread_cond_t g_life_idle_realtime = PTHREAD_COND_INITIALIZER;
static pthread_cond_t *g_life_idle;
static pthread_once_t g_life_once = PTHREAD_ONCE_INIT;
static int g_life_clock_monotonic;
static int g_runs_active;

/* How long the teardown waits for those runs before giving up on the cache. */
#define SHUTDOWN_DRAIN_TIMEOUT_S 5

/* The drain wait is bounded so a run that never returns cannot wedge the
   teardown, and a bound measured on the wall clock is not one: an NTP step
   backwards between here and the wait moves the deadline forward by the size of
   the step, so the bounded wait becomes an unbounded one on exactly the
   wedged run it exists for. CLOCK_MONOTONIC is the only clock a bounded wait
   can be expressed in, and hostexec.c already times its kill grace on it.

   pthread_cond_timedwait reads the absolute abstime through the condattr's
   clock, so the condvar and the deadline have to be switched together, which
   means this cannot stay a static initializer. Both a successful
   pthread_cond_init and a failed one leave a usable condvar behind, the second
   one on the default CLOCK_REALTIME, and the caller reads the clock the condvar
   was actually built with. */
static void life_cond_init(void) {
    pthread_condattr_t attr;
    if (pthread_condattr_init(&attr) != 0) {
        g_life_idle = &g_life_idle_realtime;
        return;
    }
    const int mono = pthread_condattr_setclock(&attr, CLOCK_MONOTONIC) == 0
                     && pthread_cond_init(&g_life_idle_monotonic, &attr) == 0;
    pthread_condattr_destroy(&attr);
    if (!mono) {
        g_life_idle = &g_life_idle_realtime;
        return;
    }
    g_life_clock_monotonic = 1;
    g_life_idle = &g_life_idle_monotonic;
}

/* Free every cached module. Only legal when no run is active, since a running
   scan may still hold one. Both locks are held by the caller, in that order,
   which is the order the teardown takes them in. */
static void cache_clear_locked(void) {
    for (int i = 0; i < g_mod_count; i++) {
        wasmtime_module_delete(g_mods[i].module);
        free(g_mods[i].path);
        g_mods[i].module = NULL;
        g_mods[i].path = NULL;
    }
    g_mod_count = 0;
}

static void run_enter(void) {
    pthread_once(&g_life_once, life_cond_init);
    pthread_mutex_lock(&g_life_lock);
    /* An entry is keyed by (path, size, mtime), so rebuilding a plugin leaves
       the old one behind forever and the cache only ever filled. A cache that
       reached MOD_CACHE_MAX is emptied here instead, at a point where no run
       is executing, because a full cache otherwise turns every later compile
       into a module nobody owns. */
    if (g_runs_active == 0) {
        pthread_mutex_lock(&g_mod_lock);
        if (g_mod_count >= MOD_CACHE_MAX) cache_clear_locked();
        pthread_mutex_unlock(&g_mod_lock);
    }
    g_runs_active++;
    pthread_mutex_unlock(&g_life_lock);
}

static void run_leave(void) {
    pthread_once(&g_life_once, life_cond_init);
    pthread_mutex_lock(&g_life_lock);
    g_runs_active--;
    if (g_runs_active == 0) pthread_cond_broadcast(g_life_idle);
    pthread_mutex_unlock(&g_life_lock);
}

static wasm_engine_t *shared_engine(void) {
    wasm_engine_t *engine;
    pthread_mutex_lock(&g_mod_lock);
    if (!g_engine) {
        /* Default cache dir (WASMTIME_CACHE_HOME or the platform cache dir).
           A read-only or missing HOME only costs compilation, never a scan.
           cordis-boundary: emission. The cache directory outlives this process
           and is not ours to revert; a failed load is dropped, not compensated. */
        wasm_config_t *cfg = wasm_config_new();
        if (cfg) {
            wasmtime_error_t *cerr = wasmtime_config_cache_config_load(cfg, NULL);
            if (cerr) wasmtime_error_delete(cerr);
            g_engine = wasm_engine_new_with_config(cfg);
        }
        if (!g_engine) g_engine = wasm_engine_new();
    }
    engine = g_engine;
    pthread_mutex_unlock(&g_mod_lock);
    return engine;
}

/* Remember a compiled module for `path`, and take ownership of it: the cache
   is the only thing that frees a module, so one it cannot store is deleted
   here. Returns 1 when the cache owns it, 0 when it does not and the caller
   must report the miss. Slots are not freed while a run may still hold one;
   a full cache is emptied between runs instead (run_enter). */
static int cache_put(const char *path, const struct stat *st, wasmtime_module_t *module) {
    char *copy = strdup(path);
    if (!copy) {
        wasmtime_module_delete(module);
        return 0;
    }
    pthread_mutex_lock(&g_mod_lock);
    if (g_mod_count < MOD_CACHE_MAX) {
        ModSlot *s = &g_mods[g_mod_count++];
        s->path = copy;
        s->size = (long)st->st_size;
        s->mtime_s = (long)st->st_mtim.tv_sec;
        s->mtime_ns = (long)st->st_mtim.tv_nsec;
        s->module = module;
        pthread_mutex_unlock(&g_mod_lock);
        return 1;
    }
    pthread_mutex_unlock(&g_mod_lock);
    free(copy);
    wasmtime_module_delete(module);
    return 0;
}

/* Which wasm a precompiled image was built from, recorded beside it as
   `<module>.wasm.cwasm.stamp` as "size mtime_s mtime_ns" of the source at
   compile time.

   The image itself carries no reference back to its source, so mtime is all a
   reader had to go on, and mtime is not an identity: the packaging scripts copy
   the wasm and the image with `cp -f` and stamp each with its own copy time, so
   an image left over from an earlier build reads as newer than the source it is
   compared against. That deserializes, and the scan then runs the old plugin.
   The stamp is written after the image is in place, so a build that dies
   between the two leaves an image with no stamp, which no reader accepts. */

#define STAMP_SUFFIX ".stamp"
#define STAMP_FORMAT "%ld %ld %ld\n"
#define STAMP_SCAN "%ld %ld %ld"

/* `path` is a wasm path; the image and its stamp are siblings of it. */
static int image_path_for(const char *wasm_path, char *out, size_t outlen) {
    int n = snprintf(out, outlen, "%s.cwasm", wasm_path);
    return n > 0 && n < (int)outlen;
}

static int stamp_path_for(const char *image_path, char *out, size_t outlen) {
    int n = snprintf(out, outlen, "%s" STAMP_SUFFIX, image_path);
    return n > 0 && n < (int)outlen;
}

/* 1 when the stamp names exactly the wasm `st` describes. A missing, short,
   unparsable or differing stamp is a miss, so an image from any other build
   costs a compile instead of serving another build's code. */
static int stamp_matches_wasm(const char *image_path, const struct stat *st) {
    char spath[4096];
    if (!stamp_path_for(image_path, spath, sizeof spath)) return 0;
    FILE *f = fopen(spath, "rb");
    if (!f) return 0;
    char line[128];
    size_t got = fread(line, 1, sizeof line - 1, f);
    fclose(f);
    line[got] = '\0';
    long size = 0, mtime_s = 0, mtime_ns = 0;
    if (sscanf(line, STAMP_SCAN, &size, &mtime_s, &mtime_ns) != 3) return 0;
    return size == (long)st->st_size && mtime_s == (long)st->st_mtim.tv_sec
        && mtime_ns == (long)st->st_mtim.tv_nsec;
}

/* Write the stamp for `wasm_path`'s image. 0 on success. The image is renamed
   into place first, so this never leaves a stamp claiming an image that is not
   there; a failure here leaves the image unusable, and the caller reports it
   rather than shipping an image no reader will accept. */
static int write_stamp(const char *wasm_path, const struct stat *st, char *err, size_t errlen) {
    Err e = {err, errlen, 0};
    char ipath[4096], spath[4096], tmp[4096];
    if (!image_path_for(wasm_path, ipath, sizeof ipath)
        || !stamp_path_for(ipath, spath, sizeof spath)) {
        fail_msg(&e, "precompiled module path too long");
        return 1;
    }
    if (snprintf(tmp, sizeof tmp, "%s.tmp", spath) >= (int)sizeof tmp) {
        fail_msg(&e, "precompiled module path too long");
        return 1;
    }
    FILE *f = fopen(tmp, "wb");
    if (!f) {
        fail_msg(&e, "cannot write precompiled module stamp");
        return 1;
    }
    const int n = fprintf(f, STAMP_FORMAT, (long)st->st_size, (long)st->st_mtim.tv_sec,
                          (long)st->st_mtim.tv_nsec);
    const int ok = n > 0 && fflush(f) == 0 && fsync(fileno(f)) == 0;
    fclose(f);
    if (!ok) {
        unlink(tmp);
        fail_msg(&e, "cannot write precompiled module stamp");
        return 1;
    }
    if (rename(tmp, spath) != 0) {
        unlink(tmp);
        fail_msg(&e, "cannot replace precompiled module stamp");
        return 1;
    }
    return 0;
}

/* Compiled module for `path`, from the cache or freshly compiled. NULL on
   error, with `e` set. The caller borrows it; the cache owns it. */
static wasmtime_module_t *module_for_path(wasm_engine_t *engine, const char *path, Err *e) {
    struct stat st;
    if (stat(path, &st) != 0) {
        size_t len = 0;
        unsigned char *bytes = read_file(path, &len, e);
        free(bytes);
        return NULL;
    }
    pthread_mutex_lock(&g_mod_lock);
    for (int i = 0; i < g_mod_count; i++) {
        ModSlot *s = &g_mods[i];
        if (s->size == (long)st.st_size && s->mtime_s == (long)st.st_mtim.tv_sec
            && s->mtime_ns == (long)st.st_mtim.tv_nsec && strcmp(s->path, path) == 0) {
            wasmtime_module_t *hit = s->module;
            pthread_mutex_unlock(&g_mod_lock);
            return hit;
        }
    }
    pthread_mutex_unlock(&g_mod_lock);

    /* Precompiled sibling written by `core/build.sh` (host --precompile):
       deserializing is far cheaper than compiling. Its stamp has to name this
       wasm: an image built from other bytes is not a faster compile, it is the
       wrong module running the scan. An unstamped or mismatched image falls
       through to compiling the wasm, which is what shipped trees without one
       did anyway. */
    char cwasm[4096];
    if (image_path_for(path, cwasm, sizeof cwasm) && stamp_matches_wasm(cwasm, &st)) {
        wasmtime_module_t *pre = NULL;
        wasmtime_error_t *perr = wasmtime_module_deserialize_file(engine, cwasm, &pre);
        if (!perr && pre) {
            if (!cache_put(path, &st, pre)) {
                fail_msg(e, "module cache is full");
                /* Nothing took the module, so this call has to drop it. */
                wasmtime_module_delete(pre);
                return NULL;
            }
            return pre;
        }
        if (perr) wasmtime_error_delete(perr);
    }

    size_t len = 0;
    unsigned char *bytes = read_file(path, &len, e);
    if (!bytes) return NULL;
    wasmtime_module_t *module = NULL;
    wasmtime_error_t *err = wasmtime_module_new(engine, bytes, len, &module);
    free(bytes);
    if (err) {
        fail_error(e, path, err);
        return NULL;
    }
    if (!cache_put(path, &st, module)) {
        fail_msg(e, "module cache is full");
        wasmtime_module_delete(module);
        return NULL;
    }
    return module;
}

static int instantiate(
    wasmtime_context_t *ctx,
    wasmtime_linker_t *linker,
    wasm_engine_t *engine,
    const char *path,
    wasmtime_module_t **out_module,
    wasmtime_instance_t *out_instance,
    Err *e
) {
    wasmtime_error_t *err;
    wasmtime_module_t *module = module_for_path(engine, path, e);
    if (!module) return 1;
    wasm_trap_t *trap = NULL;
    err = wasmtime_linker_instantiate(linker, ctx, module, out_instance, &trap);
    if (err) {
        fail_error(e, "instantiate", err);
        return 1;
    }
    if (trap) {
        fail_trap(e, "instantiate", trap);
        return 1;
    }
    *out_module = module;
    return 0;
}

static int must_export(
    wasmtime_context_t *ctx,
    const wasmtime_instance_t *instance,
    const char *name,
    wasmtime_extern_t *out,
    Err *e
) {
    if (!wasmtime_instance_export_get(ctx, instance, name, strlen(name), out)) {
        char buf[128];
        snprintf(buf, sizeof buf, "missing export %s", name);
        fail_msg(e, buf);
        return 1;
    }
    return 0;
}

static int call_i32(wasmtime_context_t *ctx, const wasmtime_func_t *fn, int32_t *out, Err *e) {
    wasmtime_val_t results[1];
    wasm_trap_t *trap = NULL;
    wasmtime_error_t *err = wasmtime_func_call(ctx, fn, NULL, 0, results, 1, &trap);
    if (err) {
        fail_error(e, "call", err);
        return 1;
    }
    if (trap) {
        fail_trap(e, "call", trap);
        return 1;
    }
    *out = results[0].of.i32;
    return 0;
}

static int call_i32_arg(
    wasmtime_context_t *ctx,
    const wasmtime_func_t *fn,
    int32_t arg,
    int32_t *out,
    Err *e
) {
    wasmtime_val_t args[1];
    args[0].kind = WASMTIME_I32;
    args[0].of.i32 = arg;
    wasmtime_val_t results[1];
    wasm_trap_t *trap = NULL;
    wasmtime_error_t *err = wasmtime_func_call(ctx, fn, args, 1, results, 1, &trap);
    if (err) {
        fail_error(e, "call", err);
        return 1;
    }
    if (trap) {
        fail_trap(e, "call", trap);
        return 1;
    }
    *out = results[0].of.i32;
    return 0;
}

static void drop_externs(wasmtime_extern_t **xs, int n) {
    int i;
    for (i = 0; i < n; i++) {
        wasmtime_extern_delete(xs[i]);
    }
}

/* Seven of these run over every plugin result, and each result is a result
   buffer the plugin deliberately fills to the brim. Testing the first byte
   before the memcmp keeps the call out of the common case: over a 64 KiB
   result with the seven host-intercept patterns, 8.4 ms to 0.4 ms per plugin
   under ASan, measured against the memcmp-at-every-offset form. */
static int contains(const uint8_t *data, size_t len, const char *needle) {
    const size_t nlen = strlen(needle);
    if (len < nlen) return 0;
    if (nlen == 0) return 1;
    if (nlen == 1) return memchr(data, needle[0], len) != NULL;
    const uint8_t first = (uint8_t)needle[0];
    for (size_t i = 0; i <= len - nlen; i++) {
        if (data[i] == first && memcmp(data + i + 1, needle + 1, nlen - 1) == 0) return 1;
    }
    return 0;
}

static wasm_functype_t *functype_i32x4_i32(void) {
    wasm_valtype_t *ps[4] = {
        wasm_valtype_new_i32(),
        wasm_valtype_new_i32(),
        wasm_valtype_new_i32(),
        wasm_valtype_new_i32(),
    };
    wasm_valtype_t *rs[1] = { wasm_valtype_new_i32() };
    wasm_valtype_vec_t params, results;
    wasm_valtype_vec_new(&params, 4, ps);
    wasm_valtype_vec_new(&results, 1, rs);
    /* wasm_functype_new copies the valtypes, so the five above are the
       caller's to free. A scan that re-runs leaks them each time. */
    wasm_functype_t *ty = wasm_functype_new(&params, &results);
    for (int i = 0; i < 4; i++) wasm_valtype_delete(ps[i]);
    wasm_valtype_delete(rs[0]);
    return ty;
}

static wasm_trap_t *host_exec_cb(
    void *env,
    wasmtime_caller_t *caller,
    const wasmtime_val_t *args,
    size_t nargs,
    wasmtime_val_t *results,
    size_t nresults
) {
    (void)env;
    results[0].kind = WASMTIME_I32;
    results[0].of.i32 = APPATTIC_HOST_EXEC_BAD;
    if (nargs != 4 || nresults != 1) return NULL;

    const int32_t cmd_ptr = args[0].of.i32;
    const int32_t cmd_len = args[1].of.i32;
    const int32_t out_ptr = args[2].of.i32;
    const int32_t out_cap = args[3].of.i32;
    if (cmd_ptr < 0 || cmd_len < 0 || out_ptr < 0 || out_cap < 0) return NULL;

    wasmtime_extern_t item;
    if (!wasmtime_caller_export_get(caller, "memory", strlen("memory"), &item) ||
        item.kind != WASMTIME_EXTERN_MEMORY) {
        return NULL;
    }
    wasmtime_context_t *ctx = wasmtime_caller_context(caller);
    uint8_t *data = wasmtime_memory_data(ctx, &item.of.memory);
    size_t mem_len = wasmtime_memory_data_size(ctx, &item.of.memory);
    if ((size_t)cmd_ptr + (size_t)cmd_len > mem_len ||
        (size_t)out_ptr + (size_t)out_cap > mem_len) {
        wasmtime_extern_delete(&item);
        return NULL;
    }

    char cmd[513];
    if ((size_t)cmd_len >= sizeof cmd) {
        results[0].of.i32 = APPATTIC_HOST_EXEC_DENY;
        wasmtime_extern_delete(&item);
        return NULL;
    }
    memcpy(cmd, data + cmd_ptr, (size_t)cmd_len);
    cmd[cmd_len] = '\0';

    const int n = appattic_host_exec(cmd, (char *)(data + out_ptr), (size_t)out_cap);
    if (n < 0) {
        results[0].of.i32 = n;
        wasmtime_extern_delete(&item);
        return NULL;
    }
    results[0].of.i32 = n;
    wasmtime_extern_delete(&item);
    return NULL;
}

static int32_t parse_tag(char *spec, char **path_out) {
    char *eq = strrchr(spec, '=');
    if (!eq) {
        *path_out = spec;
        return 1;
    }
    *eq = '\0';
    *path_out = spec;
    return (int32_t)atoi(eq + 1);
}

static void plugin_id_from_path(const char *path, char *out, size_t cap) {
    if (!out || cap == 0) return;
    out[0] = '\0';
    if (!path) return;
    const char *base = strrchr(path, '/');
    base = base ? base + 1 : path;
    size_t n = 0;
    for (; base[n] && n + 1 < cap; n++) {
        const char c = base[n];
        if (c == '.') break;
        out[n] = (c == '_') ? '-' : c;
    }
    out[n] = '\0';
}

static int run_plugin(
    wasmtime_context_t *ctx,
    wasmtime_linker_t *linker,
    wasm_engine_t *engine,
    char *spec,
    appattic_json_fn on_json,
    appattic_progress_fn on_progress,
    int index,
    int total,
    void *user,
    Err *e
) {
    char *path = NULL;
    const int32_t tag = parse_tag(spec, &path);
    char id[128];
    plugin_id_from_path(path, id, sizeof id);
    if (on_progress) on_progress(id, index, total, user);
    /* A skipped plugin is not a failure, but the skip must not erase a fault an
       earlier plugin already published on this accumulator: the two writes do
       not commute, and the skip used to win, leaving rc=1 with an empty err. */
    const int err_was_failed = e->failed;
    if (access(path, R_OK) != 0) {
        fprintf(stderr, "skip %s (missing coeffect/file)\n", path);
        return 0;
    }

    wasmtime_module_t *mod = NULL;
    wasmtime_instance_t plug;
    if (instantiate(ctx, linker, engine, path, &mod, &plug, e) != 0) {
        fprintf(stderr, "skip %s (instantiate failed)\n", path);
        if (!err_was_failed) {
            e->failed = 0;
            if (e->buf && e->len) e->buf[0] = '\0';
        }
        return 0;
    }

    wasmtime_extern_t plug_abi, id_ptr, id_len, query, res_ptr, res_len, memory;
    wasmtime_extern_t *slots[7] = {
        &plug_abi, &id_ptr, &id_len, &query, &res_ptr, &res_len, &memory
    };
    const char *names[7] = {
        "plugin_abi_version",
        "plugin_id_ptr",
        "plugin_id_len",
        "plugin_query",
        "result_ptr",
        "result_len",
        "memory"
    };
    int ngot = 0;
    int i;
    int32_t abi = 0, ip = 0, il = 0, qrc = 0, rp = 0, rl = 0;
    uint8_t *data = NULL;
    size_t mem_len = 0;
    const uint8_t *json = NULL;
    for (i = 0; i < 7; i++) {
        if (must_export(ctx, &plug, names[i], slots[i], e)) goto skip_plugin;
        ngot++;
    }
    if (memory.kind != WASMTIME_EXTERN_MEMORY ||
        plug_abi.kind != WASMTIME_EXTERN_FUNC ||
        query.kind != WASMTIME_EXTERN_FUNC) {
        fprintf(stderr, "skip %s (bad plugin exports)\n", path);
        goto skip_plugin;
    }
    if (call_i32(ctx, &plug_abi.of.func, &abi, e) != 0) goto skip_plugin;
    if (abi != 1) {
        fprintf(stderr, "skip %s (plugin abi mismatch)\n", path);
        goto skip_plugin;
    }

    if (call_i32(ctx, &id_ptr.of.func, &ip, e) != 0 ||
        call_i32(ctx, &id_len.of.func, &il, e) != 0) {
        goto skip_plugin;
    }
    data = wasmtime_memory_data(ctx, &memory.of.memory);
    mem_len = wasmtime_memory_data_size(ctx, &memory.of.memory);
    if (ip < 0 || il < 0 || (size_t)ip + (size_t)il > mem_len) {
        fprintf(stderr, "skip %s (plugin id out of memory)\n", path);
        goto skip_plugin;
    }

    if (call_i32_arg(ctx, &query.of.func, tag, &qrc, e) != 0) goto skip_plugin;
    if (qrc != 0) {
        fprintf(stderr, "skip %s (plugin_query failed)\n", path);
        goto skip_plugin;
    }
    data = wasmtime_memory_data(ctx, &memory.of.memory);
    mem_len = wasmtime_memory_data_size(ctx, &memory.of.memory);
    if (call_i32(ctx, &res_ptr.of.func, &rp, e) != 0 ||
        call_i32(ctx, &res_len.of.func, &rl, e) != 0) {
        goto skip_plugin;
    }
    if (rp < 0 || rl < 0 || (size_t)rp + (size_t)rl > mem_len) {
        fprintf(stderr, "skip %s (result out of memory)\n", path);
        goto skip_plugin;
    }
    json = data + rp;
    if (contains(json, (size_t)rl, "system prune") ||
        contains(json, (size_t)rl, "rmi -f") ||
        contains(json, (size_t)rl, "volume prune") ||
        contains(json, (size_t)rl, "snap remove --purge") ||
        contains(json, (size_t)rl, "rm /usr/bin/snap") ||
        contains(json, (size_t)rl, "rm -rf /usr/bin/snap") ||
        contains(json, (size_t)rl, "rm /usr/bin/flatpak")) {
        fail_msg(e, "host intercept: refusing bulk wipe");
        goto fail_plugin;
    }

    if (on_json) on_json((const char *)json, (size_t)rl, user);
    drop_externs(slots, ngot);
    return 0;

skip_plugin:
    drop_externs(slots, ngot);
    if (!err_was_failed) {
        e->failed = 0;
        if (e->buf && e->len) e->buf[0] = '\0';
    }
    return 0;

fail_plugin:
    drop_externs(slots, ngot);
    return 1;
}

/* Inverse of the engine and module cache above: drop every compiled module and
   the shared engine. The UI calls this from its own teardown, so the process
   singleton has an owner and a dispose instead of living until exit. Waits for
   in-flight runs first; call it from a thread that is not itself running one.
   A run that never returns (a force-terminated scan thread) must not wedge the
   teardown, so the wait is bounded and the modules are then left to the exit. */
void appattic_wasm_shutdown(void) {
    struct timespec deadline;
    pthread_once(&g_life_once, life_cond_init);
    clock_gettime(g_life_clock_monotonic ? CLOCK_MONOTONIC : CLOCK_REALTIME, &deadline);
    deadline.tv_sec += SHUTDOWN_DRAIN_TIMEOUT_S;
    pthread_mutex_lock(&g_life_lock);
    while (g_runs_active > 0) {
        if (pthread_cond_timedwait(g_life_idle, &g_life_lock, &deadline) != 0) break;
    }
    const int busy = g_runs_active;
    if (busy > 0) {
        pthread_mutex_unlock(&g_life_lock);
        fprintf(stderr, "wasm: %d run(s) still active, keeping the engine\n", busy);
        return;
    }
    /* g_life_lock stays held across the teardown, and run_enter takes it
       first: a run that starts after the drain would otherwise take the engine
       and a cached module from under the delete below. g_life_lock is the
       outer lock everywhere, including the empty-between-runs path in
       run_enter, so taking g_mod_lock under it cannot invert against another
       path. */
    pthread_mutex_lock(&g_mod_lock);
    cache_clear_locked();
    if (g_engine) {
        wasm_engine_delete(g_engine);
        g_engine = NULL;
    }
    pthread_mutex_unlock(&g_mod_lock);
    pthread_mutex_unlock(&g_life_lock);
}

/* Compile `wasm_path` and write the serialized image to `out_path`, so
   core/build.sh can ship a precompiled module beside the wasm. */
static int precompile_locked(
    const char *wasm_path,
    const char *out_path,
    char *err,
    size_t errlen
) {
    Err e = {err, errlen, 0};
    wasm_engine_t *engine = shared_engine();
    if (!engine) {
        fail_msg(&e, "wasm_engine_new failed");
        return 1;
    }
    wasmtime_module_t *module = module_for_path(engine, wasm_path, &e);
    if (!module) return 1;
    wasm_byte_vec_t image;
    wasmtime_error_t *serr = wasmtime_module_serialize(module, &image);
    if (serr) {
        fail_error(&e, "serialize", serr);
        return 1;
    }
    const size_t n = image.size;
    /* `module_for_path` deserializes `<module>.cwasm` whenever its stamp names
       this wasm, so writing the image in place would let a reader, or a crash,
       see a truncated module under a stamp that still matches. Write a sibling
       temp and rename: rename is atomic within the directory, so a reader sees
       the old image or the new one and never a partial one. */
    char tmp_path[4096];
    if (snprintf(tmp_path, sizeof tmp_path, "%s.tmp", out_path) >= (int)sizeof tmp_path) {
        fail_msg(&e, "precompiled module path too long");
        wasm_byte_vec_delete(&image);
        return 1;
    }
    FILE *f = fopen(tmp_path, "wb");
    if (!f) {
        fail_msg(&e, "cannot write precompiled module");
        wasm_byte_vec_delete(&image);
        return 1;
    }
    /* A flush or fsync that failed leaves bytes the kernel never took, and the
       rename below would publish the image and the stamp that makes a reader
       accept it: a truncated module deserialized as a valid one. Same rule as
       write_stamp, so both halves of the pair report it. */
    const size_t wrote = fwrite(image.data, 1, n, f);
    const int flushed = fflush(f) == 0 && fsync(fileno(f)) == 0;
    fclose(f);
    wasm_byte_vec_delete(&image);
    if (wrote != n) {
        unlink(tmp_path);
        fail_msg(&e, "short write");
        return 1;
    }
    if (!flushed) {
        unlink(tmp_path);
        fail_msg(&e, "cannot flush precompiled module");
        return 1;
    }
    if (rename(tmp_path, out_path) != 0) {
        unlink(tmp_path);
        fail_msg(&e, "cannot replace precompiled module");
        return 1;
    }
    /* The image is in place; stamp it with the wasm it came from. Without this
       the image is dead weight: no reader accepts an unstamped one. */
    struct stat src;
    if (stat(wasm_path, &src) != 0) {
        fail_msg(&e, "cannot stat precompiled module source");
        return 1;
    }
    if (write_stamp(wasm_path, &src, err, errlen) != 0) {
        unlink(out_path);
        return 1;
    }
    return 0;
}

int appattic_precompile(const char *wasm_path, const char *out_path, char *err, size_t errlen) {
    run_enter();
    const int rc = precompile_locked(wasm_path, out_path, err, errlen);
    run_leave();
    return rc;
}

static int wasm_run_locked(
    const char *core_wasm,
    char **plugin_specs,
    int plugin_count,
    appattic_json_fn on_json,
    appattic_progress_fn on_progress,
    void *user,
    char *err,
    size_t errlen
) {
    Err e = {err, errlen, 0};
    if (!core_wasm || plugin_count < 1) {
        fail_msg(&e, "usage: <core.wasm> <plugin.wasm[=tag]>...");
        return 2;
    }

    wasm_engine_t *engine_rt = shared_engine();
    if (!engine_rt) {
        fail_msg(&e, "wasm_engine_new failed");
        return 1;
    }
    wasmtime_linker_t *linker = wasmtime_linker_new(engine_rt);
    if (!linker) {
        fail_msg(&e, "wasmtime_linker_new failed");
        return 1;
    }
    wasm_functype_t *exec_ty = functype_i32x4_i32();
    wasmtime_error_t *link_err = wasmtime_linker_define_func(
        linker, "host", 4, "exec", 4, exec_ty, host_exec_cb, NULL, NULL
    );
    wasm_functype_delete(exec_ty);
    if (link_err) {
        fail_error(&e, "define host.exec", link_err);
        wasmtime_linker_delete(linker);
        return 1;
    }

    wasmtime_store_t *store = wasmtime_store_new(engine_rt, NULL, NULL);
    wasmtime_context_t *ctx = wasmtime_store_context(store);

    wasmtime_module_t *core_mod = NULL;
    wasmtime_instance_t core;
    if (instantiate(ctx, linker, engine_rt, core_wasm, &core_mod, &core, &e) != 0) {
        wasmtime_store_delete(store);
        wasmtime_linker_delete(linker);
        return 1;
    }
    wasmtime_extern_t core_abi;
    if (must_export(ctx, &core, "core_abi_version", &core_abi, &e)) {
        wasmtime_store_delete(store);
        wasmtime_linker_delete(linker);
        return 1;
    }
    if (core_abi.kind != WASMTIME_EXTERN_FUNC) {
        fail_msg(&e, "core exports must be functions");
        wasmtime_extern_delete(&core_abi);
        wasmtime_store_delete(store);
        wasmtime_linker_delete(linker);
        return 1;
    }
    int32_t abi = 0;
    if (call_i32(ctx, &core_abi.of.func, &abi, &e) != 0) {
        wasmtime_extern_delete(&core_abi);
        wasmtime_store_delete(store);
        wasmtime_linker_delete(linker);
        return 1;
    }
    if (abi != 1) {
        fail_msg(&e, "unsupported core abi");
        wasmtime_extern_delete(&core_abi);
        wasmtime_store_delete(store);
        wasmtime_linker_delete(linker);
        return 1;
    }

    int rc = 0;
    for (int i = 0; i < plugin_count; i++) {
        if (appattic_host_exec_cancelled()) break;
        if (run_plugin(
                ctx,
                linker,
                engine_rt,
                plugin_specs[i],
                on_json,
                on_progress,
                i + 1,
                plugin_count,
                user,
                &e
            ) != 0) {
            rc = 1;
        }
    }

    wasmtime_extern_delete(&core_abi);
    wasmtime_store_delete(store);
    wasmtime_linker_delete(linker);
    return rc;
}

int appattic_wasm_run(
    const char *core_wasm,
    char **plugin_specs,
    int plugin_count,
    appattic_json_fn on_json,
    appattic_progress_fn on_progress,
    void *user,
    char *err,
    size_t errlen
) {
    run_enter();
    const int rc = wasm_run_locked(
        core_wasm, plugin_specs, plugin_count, on_json, on_progress, user, err, errlen
    );
    run_leave();
    return rc;
}
