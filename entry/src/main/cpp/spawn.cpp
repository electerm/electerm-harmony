/*
 * spawn.cpp — NAPI module for spawning child processes on HarmonyOS.
 *
 * HarmonyOS's @ohos.process.runCmd is a @systemapi (system-only API),
 * unavailable to third-party apps.  This NAPI module provides the same
 * capability via posix_spawn(3), which is a POSIX standard C library
 * function and is not restricted by the SDK's systemapi gate.
 *
 * Exposed functions (TypeScript declarations in types/libspawn/Index.d.ts):
 *   - spawnProcess(binPath, args): number  — returns PID (>0) or throws
 *   - killProcess(pid, signal): boolean    — sends signal to process
 *   - waitProcess(pid): Promise<number>    — resolves with exit code
 */

#include "napi/native_api.h"

#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <string>
#include <vector>

extern char **environ;

/* ------------------------------------------------------------------ */
/*  spawnProcess                                                       */
/* ------------------------------------------------------------------ */

static napi_value SpawnProcess(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_status st = napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (st != napi_ok || argc < 2) {
        napi_throw_type_error(env, nullptr,
            "Expected 2 arguments: binPath (string), args (string[])");
        return nullptr;
    }

    /* --- Read binary path --- */
    size_t pathLen = 0;
    napi_get_value_string_utf8(env, args[0], nullptr, 0, &pathLen);
    if (pathLen == 0 || pathLen >= 4096) {
        napi_throw_type_error(env, nullptr, "binPath is empty or too long");
        return nullptr;
    }
    std::string binPath(pathLen + 1, '\0');
    napi_get_value_string_utf8(env, args[0], &binPath[0], pathLen + 1, &pathLen);
    binPath.resize(pathLen);

    /* --- Read arguments array --- */
    bool isArray = false;
    napi_is_array(env, args[1], &isArray);
    if (!isArray) {
        napi_throw_type_error(env, nullptr, "args must be an array of strings");
        return nullptr;
    }

    uint32_t argCount = 0;
    napi_get_array_length(env, args[1], &argCount);

    /* Build argv: [binPath, arg0, arg1, ..., nullptr] */
    std::vector<std::string> argStrings;
    std::vector<char *> argv;

    argStrings.push_back(binPath);  /* argv[0] = program name */
    argv.push_back(&argStrings.back()[0]);

    for (uint32_t i = 0; i < argCount; i++) {
        napi_value elem;
        napi_get_element(env, args[1], i, &elem);

        size_t elemLen = 0;
        napi_get_value_string_utf8(env, elem, nullptr, 0, &elemLen);
        std::string argStr(elemLen + 1, '\0');
        napi_get_value_string_utf8(env, elem, &argStr[0], elemLen + 1, &elemLen);
        argStr.resize(elemLen);

        argStrings.push_back(std::move(argStr));
        argv.push_back(&argStrings.back()[0]);
    }
    argv.push_back(nullptr);

    /* --- Spawn the process --- */
    pid_t pid = 0;
    int ret = posix_spawnp(&pid, binPath.c_str(),
                           nullptr, nullptr, argv.data(), environ);

    if (ret != 0) {
        char errBuf[512];
        snprintf(errBuf, sizeof(errBuf),
                 "posix_spawnp failed: %s (errno=%d, path=%s)",
                 strerror(ret), ret, binPath.c_str());
        napi_throw_error(env, "SPAWN_ERROR", errBuf);
        return nullptr;
    }

    napi_value pidValue;
    napi_create_int32(env, pid, &pidValue);
    return pidValue;
}

/* ------------------------------------------------------------------ */
/*  killProcess                                                        */
/* ------------------------------------------------------------------ */

static napi_value KillProcess(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t pid = 0;
    int32_t signal = 9;  /* default SIGKILL */
    napi_get_value_int32(env, args[0], &pid);
    if (argc >= 2) {
        napi_get_value_int32(env, args[1], &signal);
    }

    int ret = kill(pid, signal);
    napi_value result;
    napi_get_boolean(env, ret == 0, &result);
    return result;
}

/* ------------------------------------------------------------------ */
/*  waitProcess  (uses napi_async_work for thread safety)              */
/* ------------------------------------------------------------------ */

typedef struct {
    pid_t  pid;
    int    exitCode;
    napi_async_work work;
    napi_deferred deferred;
} WaitContext;

static void WaitExecute(napi_env env, void *data) {
    WaitContext *ctx = (WaitContext *)data;
    int status = 0;
    pid_t ret = waitpid(ctx->pid, &status, 0);
    if (ret > 0 && WIFEXITED(status)) {
        ctx->exitCode = WEXITSTATUS(status);
    } else {
        ctx->exitCode = -1;
    }
}

static void WaitComplete(napi_env env, napi_status status, void *data) {
    WaitContext *ctx = (WaitContext *)data;

    napi_value exitCodeVal;
    napi_create_int32(env, ctx->exitCode, &exitCodeVal);

    if (ctx->exitCode >= 0) {
        napi_resolve_deferred(env, ctx->deferred, exitCodeVal);
    } else {
        napi_reject_deferred(env, ctx->deferred, exitCodeVal);
    }

    napi_delete_async_work(env, ctx->work);
    delete ctx;
}

static napi_value WaitProcess(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t pid = 0;
    napi_get_value_int32(env, args[0], &pid);

    WaitContext *ctx = new WaitContext();
    ctx->pid = pid;
    ctx->exitCode = -1;

    napi_value promise;
    napi_create_promise(env, &ctx->deferred, &promise);

    napi_value name;
    napi_create_string_utf8(env, "waitProcess", NAPI_AUTO_LENGTH, &name);

    napi_create_async_work(env, nullptr, name, WaitExecute, WaitComplete,
                           ctx, &ctx->work);
    napi_queue_async_work(env, ctx->work);

    return promise;
}

/* ------------------------------------------------------------------ */
/*  Module registration                                                */
/* ------------------------------------------------------------------ */

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"spawnProcess", nullptr, SpawnProcess, nullptr, nullptr, nullptr,
            napi_default, nullptr},
        {"killProcess",  nullptr, KillProcess,  nullptr, nullptr, nullptr,
            napi_default, nullptr},
        {"waitProcess",  nullptr, WaitProcess,  nullptr, nullptr, nullptr,
            napi_default, nullptr},
    };
    napi_define_properties(env, exports,
                           sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module spawnModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "spawn",
    .nm_priv = ((void *)0),
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterSpawnModule(void) {
    napi_module_register(&spawnModule);
}
