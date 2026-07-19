/*
 * spawn.cpp — NAPI module for spawning child processes on HarmonyOS.
 *
 * HarmonyOS's @ohos.process.runCmd is a @systemapi (system-only API),
 * unavailable to third-party apps.  This NAPI module provides the same
 * capability via posix_spawn(3), which is a POSIX standard C library
 * function and is not restricted by the SDK's systemapi gate.
 *
 * Exposed functions (TypeScript declarations in types/libspawn/Index.d.ts):
 *   - spawnProcess(binPath, args, env?): number  — returns PID (>0) or throws
 *   - killProcess(pid, signal): boolean    — sends signal to process
 *   - waitProcess(pid): Promise<number>    — resolves with exit code
 *   - chmod(path, mode): boolean           — changes file permissions
 */

#include "napi/native_api.h"

#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <sys/stat.h>
#include <stdlib.h>
#include <string>
#include <vector>

extern char **environ;

/* ------------------------------------------------------------------ */
/*  Helper: build envp array from current environ + extra vars         */
/* ------------------------------------------------------------------ */

/**
 * Builds a new envp[] array that is a copy of the current environment
 * (environ) with any extra key=value strings appended.  If a key already
 * exists in the environment, the extra value takes precedence because it
 * appears later (most libc implementations use the last occurrence).
 *
 * The returned vector and the strings it points to must remain alive until
 * after posix_spawn returns.  The caller is responsible for keeping
 * `storage` alive.
 */
static std::vector<char *> buildEnvp(
    const std::vector<std::string> &extra,
    std::vector<std::string> &storage)
{
    std::vector<char *> envp;

    /* Copy current environ strings into storage */
    for (char **e = environ; e && *e; e++) {
        storage.push_back(*e);
        envp.push_back(&storage.back()[0]);
    }

    /* Append extra key=value strings */
    for (const auto &s : extra) {
        storage.push_back(s);
        envp.push_back(&storage.back()[0]);
    }

    envp.push_back(nullptr);
    return envp;
}

/* ------------------------------------------------------------------ */
/*  spawnProcess(binPath, args, env?)                                  */
/*                                                                    */
/*  env is an optional object of { key: value } string pairs that     */
/*  are added to (or override) the inherited environment.             */
/* ------------------------------------------------------------------ */

static napi_value SpawnProcess(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_status st = napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (st != napi_ok || argc < 2) {
        napi_throw_type_error(env, nullptr,
            "Expected 2-3 arguments: binPath (string), args (string[]), [env (object)]");
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

    /* --- Read optional env object --- */
    std::vector<std::string> extraEnv;
    std::vector<std::string> envStorage;

    if (argc >= 3) {
        napi_valuetype envType;
        napi_typeof(env, args[2], &envType);
        if (envType == napi_object) {
            napi_value keys;
            napi_get_property_names(env, args[2], &keys);

            uint32_t keyCount = 0;
            napi_get_array_length(env, keys, &keyCount);

            for (uint32_t i = 0; i < keyCount; i++) {
                napi_value key;
                napi_get_element(env, keys, i, &key);

                size_t keyLen = 0;
                napi_get_value_string_utf8(env, key, nullptr, 0, &keyLen);
                std::string keyStr(keyLen + 1, '\0');
                napi_get_value_string_utf8(env, key, &keyStr[0], keyLen + 1, &keyLen);
                keyStr.resize(keyLen);

                napi_value val;
                napi_get_property(env, args[2], key, &val);

                size_t valLen = 0;
                napi_get_value_string_utf8(env, val, nullptr, 0, &valLen);
                std::string valStr(valLen + 1, '\0');
                napi_get_value_string_utf8(env, val, &valStr[0], valLen + 1, &valLen);
                valStr.resize(valLen);

                extraEnv.push_back(keyStr + "=" + valStr);
            }
        }
    }

    /* --- Build envp --- */
    std::vector<char *> envp = buildEnvp(extraEnv, envStorage);

    /* --- Spawn the process --- */
    /* Use posix_spawn (not posix_spawnp) since we have a full path */
    pid_t pid = 0;
    int ret = posix_spawn(&pid, binPath.c_str(),
                           nullptr, nullptr, argv.data(), envp.data());

    if (ret != 0) {
        char errBuf[512];
        snprintf(errBuf, sizeof(errBuf),
                 "posix_spawn failed: %s (errno=%d, path=%s)",
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
/*  chmod  (set file permissions)                                      */
/* ------------------------------------------------------------------ */

static napi_value Chmod(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    size_t pathLen = 0;
    napi_get_value_string_utf8(env, args[0], nullptr, 0, &pathLen);
    std::string path(pathLen + 1, '\0');
    napi_get_value_string_utf8(env, args[0], &path[0], pathLen + 1, &pathLen);
    path.resize(pathLen);

    int32_t mode = 0;
    napi_get_value_int32(env, args[1], &mode);

    int ret = chmod(path.c_str(), (mode_t)mode);
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
        {"chmod",        nullptr, Chmod,        nullptr, nullptr, nullptr,
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
