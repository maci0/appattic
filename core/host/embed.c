#include "embed.h"
#include "hostexec.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
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

static int instantiate(
    wasmtime_context_t *ctx,
    wasmtime_linker_t *linker,
    wasm_engine_t *engine,
    const char *path,
    wasmtime_module_t **out_module,
    wasmtime_instance_t *out_instance,
    Err *e
) {
    size_t len = 0;
    unsigned char *bytes = read_file(path, &len, e);
    if (!bytes) return 1;
    wasmtime_module_t *module = NULL;
    wasmtime_error_t *err = wasmtime_module_new(engine, bytes, len, &module);
    free(bytes);
    if (err) {
        fail_error(e, path, err);
        return 1;
    }
    wasm_trap_t *trap = NULL;
    err = wasmtime_linker_instantiate(linker, ctx, module, out_instance, &trap);
    if (err) {
        wasmtime_module_delete(module);
        fail_error(e, "instantiate", err);
        return 1;
    }
    if (trap) {
        wasmtime_module_delete(module);
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

static int contains(const uint8_t *data, size_t len, const char *needle) {
    const size_t nlen = strlen(needle);
    if (len < nlen) return 0;
    for (size_t i = 0; i <= len - nlen; i++) {
        if (memcmp(data + i, needle, nlen) == 0) return 1;
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
    return wasm_functype_new(&params, &results);
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

    char tmp[8192];
    const int n = appattic_host_exec(cmd, tmp, sizeof tmp);
    if (n < 0) {
        results[0].of.i32 = n;
        wasmtime_extern_delete(&item);
        return NULL;
    }
    if ((size_t)n > (size_t)out_cap) {
        results[0].of.i32 = APPATTIC_HOST_EXEC_BAD;
        wasmtime_extern_delete(&item);
        return NULL;
    }
    memcpy(data + out_ptr, tmp, (size_t)n);
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

static int run_plugin(
    wasmtime_context_t *ctx,
    wasmtime_linker_t *linker,
    wasm_engine_t *engine,
    char *spec,
    appattic_json_fn on_json,
    void *user,
    Err *e
) {
    char *path = NULL;
    const int32_t tag = parse_tag(spec, &path);
    if (access(path, R_OK) != 0) {
        fprintf(stderr, "skip %s (missing coeffect/file)\n", path);
        return 0;
    }

    wasmtime_module_t *mod = NULL;
    wasmtime_instance_t plug;
    if (instantiate(ctx, linker, engine, path, &mod, &plug, e) != 0) return 1;

    wasmtime_extern_t plug_abi, id_ptr, id_len, query, res_ptr, res_len, memory;
    if (must_export(ctx, &plug, "plugin_abi_version", &plug_abi, e) ||
        must_export(ctx, &plug, "plugin_id_ptr", &id_ptr, e) ||
        must_export(ctx, &plug, "plugin_id_len", &id_len, e) ||
        must_export(ctx, &plug, "plugin_query", &query, e) ||
        must_export(ctx, &plug, "result_ptr", &res_ptr, e) ||
        must_export(ctx, &plug, "result_len", &res_len, e) ||
        must_export(ctx, &plug, "memory", &memory, e)) {
        wasmtime_module_delete(mod);
        return 1;
    }
    if (memory.kind != WASMTIME_EXTERN_MEMORY ||
        plug_abi.kind != WASMTIME_EXTERN_FUNC ||
        query.kind != WASMTIME_EXTERN_FUNC) {
        fail_msg(e, "bad plugin exports");
        wasmtime_module_delete(mod);
        return 1;
    }
    int32_t abi = 0;
    if (call_i32(ctx, &plug_abi.of.func, &abi, e) != 0) {
        wasmtime_module_delete(mod);
        return 1;
    }
    if (abi != 1) {
        fail_msg(e, "plugin abi mismatch");
        wasmtime_module_delete(mod);
        return 1;
    }

    uint8_t *data = wasmtime_memory_data(ctx, &memory.of.memory);
    size_t mem_len = wasmtime_memory_data_size(ctx, &memory.of.memory);
    int32_t ip = 0, il = 0;
    if (call_i32(ctx, &id_ptr.of.func, &ip, e) != 0 ||
        call_i32(ctx, &id_len.of.func, &il, e) != 0) {
        wasmtime_module_delete(mod);
        return 1;
    }
    if (ip < 0 || il < 0 || (size_t)ip + (size_t)il > mem_len) {
        fail_msg(e, "plugin id out of memory");
        wasmtime_module_delete(mod);
        return 1;
    }

    int32_t qrc = 0;
    if (call_i32_arg(ctx, &query.of.func, tag, &qrc, e) != 0) {
        wasmtime_module_delete(mod);
        return 1;
    }
    if (qrc != 0) {
        fail_msg(e, "plugin_query failed");
        wasmtime_module_delete(mod);
        return 1;
    }
    int32_t rp = 0, rl = 0;
    if (call_i32(ctx, &res_ptr.of.func, &rp, e) != 0 ||
        call_i32(ctx, &res_len.of.func, &rl, e) != 0) {
        wasmtime_module_delete(mod);
        return 1;
    }
    if (rp < 0 || rl < 0 || (size_t)rp + (size_t)rl > mem_len) {
        fail_msg(e, "result out of memory");
        wasmtime_module_delete(mod);
        return 1;
    }
    const uint8_t *json = data + rp;
    if (contains(json, (size_t)rl, "system prune") ||
        contains(json, (size_t)rl, "rmi -f") ||
        contains(json, (size_t)rl, "volume prune") ||
        contains(json, (size_t)rl, "snap remove --purge") ||
        contains(json, (size_t)rl, "rm /usr/bin/snap") ||
        contains(json, (size_t)rl, "rm -rf /usr/bin/snap") ||
        contains(json, (size_t)rl, "rm /usr/bin/flatpak")) {
        fail_msg(e, "host intercept: refusing bulk wipe");
        wasmtime_module_delete(mod);
        return 1;
    }

    if (on_json) on_json((const char *)json, (size_t)rl, user);

    wasmtime_extern_delete(&plug_abi);
    wasmtime_extern_delete(&id_ptr);
    wasmtime_extern_delete(&id_len);
    wasmtime_extern_delete(&query);
    wasmtime_extern_delete(&res_ptr);
    wasmtime_extern_delete(&res_len);
    wasmtime_extern_delete(&memory);
    wasmtime_module_delete(mod);
    return 0;
}

int appattic_wasm_run(
    const char *core_wasm,
    char **plugin_specs,
    int plugin_count,
    appattic_json_fn on_json,
    void *user,
    char *err,
    size_t errlen
) {
    Err e = {err, errlen, 0};
    if (!core_wasm || plugin_count < 1) {
        fail_msg(&e, "usage: <core.wasm> <plugin.wasm[=tag]>...");
        return 2;
    }

    wasm_engine_t *engine_rt = wasm_engine_new();
    if (!engine_rt) {
        fail_msg(&e, "wasm_engine_new failed");
        return 1;
    }
    wasmtime_linker_t *linker = wasmtime_linker_new(engine_rt);
    if (!linker) {
        fail_msg(&e, "wasmtime_linker_new failed");
        wasm_engine_delete(engine_rt);
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
        wasm_engine_delete(engine_rt);
        return 1;
    }

    wasmtime_store_t *store = wasmtime_store_new(engine_rt, NULL, NULL);
    wasmtime_context_t *ctx = wasmtime_store_context(store);

    wasmtime_module_t *core_mod = NULL;
    wasmtime_instance_t core;
    if (instantiate(ctx, linker, engine_rt, core_wasm, &core_mod, &core, &e) != 0) {
        wasmtime_store_delete(store);
        wasmtime_linker_delete(linker);
        wasm_engine_delete(engine_rt);
        return 1;
    }
    wasmtime_extern_t core_abi, core_pabi;
    if (must_export(ctx, &core, "core_abi_version", &core_abi, &e) ||
        must_export(ctx, &core, "core_plugin_abi_version", &core_pabi, &e)) {
        wasmtime_module_delete(core_mod);
        wasmtime_store_delete(store);
        wasmtime_linker_delete(linker);
        wasm_engine_delete(engine_rt);
        return 1;
    }
    if (core_abi.kind != WASMTIME_EXTERN_FUNC || core_pabi.kind != WASMTIME_EXTERN_FUNC) {
        fail_msg(&e, "core exports must be functions");
        wasmtime_module_delete(core_mod);
        wasmtime_store_delete(store);
        wasmtime_linker_delete(linker);
        wasm_engine_delete(engine_rt);
        return 1;
    }
    int32_t abi = 0, pabi = 0;
    if (call_i32(ctx, &core_abi.of.func, &abi, &e) != 0 ||
        call_i32(ctx, &core_pabi.of.func, &pabi, &e) != 0) {
        wasmtime_module_delete(core_mod);
        wasmtime_store_delete(store);
        wasmtime_linker_delete(linker);
        wasm_engine_delete(engine_rt);
        return 1;
    }
    if (abi != 1 || pabi != 1) {
        fail_msg(&e, "unsupported core abi");
        wasmtime_module_delete(core_mod);
        wasmtime_store_delete(store);
        wasmtime_linker_delete(linker);
        wasm_engine_delete(engine_rt);
        return 1;
    }

    int rc = 0;
    for (int i = 0; i < plugin_count; i++) {
        if (run_plugin(ctx, linker, engine_rt, plugin_specs[i], on_json, user, &e) != 0) rc = 1;
    }

    wasmtime_extern_delete(&core_abi);
    wasmtime_extern_delete(&core_pabi);
    wasmtime_module_delete(core_mod);
    wasmtime_store_delete(store);
    wasmtime_linker_delete(linker);
    wasm_engine_delete(engine_rt);
    return rc;
}
