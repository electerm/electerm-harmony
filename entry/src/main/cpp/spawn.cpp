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
#include <fcntl.h>
#include <elf.h>
#include <dirent.h>
#include <sys/mman.h>
#include <sys/syscall.h>

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
/*  resolveFd(fd) — resolve the real path of an open file descriptor   */
/*                                                                    */
/*  HarmonyOS sandbox paths like /data/storage/el2/base/... are        */
/*  virtual — only visible to ArkTS fs APIs, not to native POSIX       */
/*  calls.  But when ArkTS opens a file via fs.openSync(), the         */
/*  returned fd is a real kernel fd pointing to the real file.         */
/*  /proc/self/fd/<fd> is a symlink to the real path.                  */
/*                                                                    */
/*  This function reads that symlink to discover the real physical     */
/*  path that native code (posix_spawn, chmod, etc.) can use.          */
/* ------------------------------------------------------------------ */

static napi_value ResolveFd(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc < 1) {
        napi_throw_type_error(env, nullptr, "Expected 1 argument: fd (number)");
        return nullptr;
    }

    int32_t fd = -1;
    napi_get_value_int32(env, args[0], &fd);

    if (fd < 0) {
        napi_throw_type_error(env, nullptr, "fd must be a non-negative integer");
        return nullptr;
    }

    char procPath[64];
    snprintf(procPath, sizeof(procPath), "/proc/self/fd/%d", fd);

    char realPath[4096];
    ssize_t len = readlink(procPath, realPath, sizeof(realPath) - 1);
    if (len < 0) {
        char errBuf[256];
        snprintf(errBuf, sizeof(errBuf),
                 "readlink(/proc/self/fd/%d) failed: %s", fd, strerror(errno));
        napi_throw_error(env, "RESOLVE_ERROR", errBuf);
        return nullptr;
    }
    realPath[len] = '\0';

    napi_value result;
    napi_create_string_utf8(env, realPath, NAPI_AUTO_LENGTH, &result);
    return result;
}

/* ------------------------------------------------------------------ */
/*  diagnose(path) — return detailed info about a binary file          */
/* ------------------------------------------------------------------ */

static napi_value Diagnose(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    size_t pathLen = 0;
    napi_get_value_string_utf8(env, args[0], nullptr, 0, &pathLen);
    std::string path(pathLen + 1, '\0');
    napi_get_value_string_utf8(env, args[0], &path[0], pathLen + 1, &pathLen);
    path.resize(pathLen);

    napi_value result;
    napi_create_object(env, &result);

    /* Check file existence and accessibility */
    napi_value existsVal, execVal, errMsg;
    napi_get_boolean(env, access(path.c_str(), F_OK) == 0, &existsVal);
    napi_get_boolean(env, access(path.c_str(), X_OK) == 0, &execVal);
    napi_set_named_property(env, result, "exists", existsVal);
    napi_set_named_property(env, result, "executable", execVal);

    /* Get file stat info */
    struct stat st;
    char statBuf[256];
    if (stat(path.c_str(), &st) == 0) {
        snprintf(statBuf, sizeof(statBuf), "mode=%o size=%lld uid=%d gid=%d",
                 st.st_mode, (long long)st.st_size, st.st_uid, st.st_gid);
    } else {
        snprintf(statBuf, sizeof(statBuf), "stat failed: %s", strerror(errno));
    }
    napi_create_string_utf8(env, statBuf, NAPI_AUTO_LENGTH, &errMsg);
    napi_set_named_property(env, result, "stat", errMsg);

    /* Read ELF header to get interpreter path */
    int fd = open(path.c_str(), O_RDONLY);
    char interpBuf[512] = {0};
    char magicBuf[256] = {0};

    if (fd >= 0) {
        /* Read first 4 bytes for magic */
        unsigned char magic[4];
        if (read(fd, magic, 4) == 4) {
            snprintf(magicBuf, sizeof(magicBuf),
                     "0x%02x 0x%02x 0x%02x 0x%02x%s",
                     magic[0], magic[1], magic[2], magic[3],
                     (magic[0] == 0x7f && magic[1] == 'E' &&
                      magic[2] == 'L' && magic[3] == 'F')
                         ? " (ELF!)" : " (NOT ELF)");
        }

        /* Read full ELF header */
        lseek(fd, 0, SEEK_SET);
        Elf64_Ehdr ehdr;
        if (read(fd, &ehdr, sizeof(ehdr)) == sizeof(ehdr)) {
            /* Read program headers to find PT_INTERP */
            Elf64_Phdr phdr;
            for (int i = 0; i < ehdr.e_phnum; i++) {
                lseek(fd, ehdr.e_phoff + i * sizeof(Elf64_Phdr), SEEK_SET);
                if (read(fd, &phdr, sizeof(phdr)) != sizeof(phdr)) break;
                if (phdr.p_type == PT_INTERP) {
                    lseek(fd, phdr.p_offset, SEEK_SET);
                    read(fd, interpBuf,
                         phdr.p_filesz < sizeof(interpBuf)
                             ? phdr.p_filesz : sizeof(interpBuf) - 1);
                    break;
                }
            }
        }
        close(fd);
    } else {
        snprintf(magicBuf, sizeof(magicBuf), "open failed: %s", strerror(errno));
    }

    napi_create_string_utf8(env, magicBuf, NAPI_AUTO_LENGTH, &errMsg);
    napi_set_named_property(env, result, "magic", errMsg);

    napi_create_string_utf8(env, interpBuf[0] ? interpBuf : "(none)",
                            NAPI_AUTO_LENGTH, &errMsg);
    napi_set_named_property(env, result, "interpreter", errMsg);

    /* Check if interpreter exists */
    if (interpBuf[0]) {
        napi_value interpExists;
        napi_get_boolean(env, access(interpBuf, F_OK) == 0, &interpExists);
        napi_set_named_property(env, result, "interpreterExists", interpExists);
    } else {
        napi_value interpExists;
        napi_get_boolean(env, false, &interpExists);
        napi_set_named_property(env, result, "interpreterExists", interpExists);
    }

    /* Add getcwd and realpath for filesystem context diagnostics */
    char cwdBuf[4096] = {0};
    if (getcwd(cwdBuf, sizeof(cwdBuf) - 1)) {
        napi_create_string_utf8(env, cwdBuf, NAPI_AUTO_LENGTH, &errMsg);
    } else {
        napi_create_string_utf8(env, "getcwd failed", NAPI_AUTO_LENGTH, &errMsg);
    }
    napi_set_named_property(env, result, "cwd", errMsg);

    /* Try realpath on the binary path */
    char realBuf[4096] = {0};
    if (realpath(path.c_str(), realBuf)) {
        napi_create_string_utf8(env, realBuf, NAPI_AUTO_LENGTH, &errMsg);
    } else {
        snprintf(realBuf, sizeof(realBuf), "realpath failed: %s", strerror(errno));
        napi_create_string_utf8(env, realBuf, NAPI_AUTO_LENGTH, &errMsg);
    }
    napi_set_named_property(env, result, "realpath", errMsg);

    /* Try listing the parent directory */
    std::string parentDir = path.substr(0, path.find_last_of('/'));
    DIR *dir = opendir(parentDir.c_str());
    char listBuf[1024] = {0};
    if (dir) {
        struct dirent *entry;
        int offset = 0;
        while ((entry = readdir(dir)) != nullptr && offset < 900) {
            offset += snprintf(listBuf + offset, sizeof(listBuf) - offset,
                               "%s ", entry->d_name);
        }
        closedir(dir);
    } else {
        snprintf(listBuf, sizeof(listBuf), "opendir failed: %s", strerror(errno));
    }
    napi_create_string_utf8(env, listBuf, NAPI_AUTO_LENGTH, &errMsg);
    napi_set_named_property(env, result, "dirListing", errMsg);

    return result;
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
/*  chmod  (set file permissions via path — may not work on sandbox)   */
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
/*  fchmodFd  (set file permissions via fd — works on sandbox files)    */
/*                                                                    */
/*  ArkTS opens a file via fs.openSync(), getting a real kernel fd.    */
/*  fchmod(fd, mode) works on the fd directly, bypassing path          */
/*  resolution — so it works even for HarmonyOS sandbox virtual paths. */
/* ------------------------------------------------------------------ */

static napi_value FchmodFd(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc < 2) {
        napi_throw_type_error(env, nullptr,
            "Expected 2 arguments: fd (number), mode (number)");
        return nullptr;
    }

    int32_t fd = -1;
    napi_get_value_int32(env, args[0], &fd);
    if (fd < 0) {
        napi_throw_type_error(env, nullptr, "fd must be a non-negative integer");
        return nullptr;
    }

    int32_t mode = 0;
    napi_get_value_int32(env, args[1], &mode);

    int ret = fchmod(fd, (mode_t)mode);
    if (ret != 0) {
        char errBuf[256];
        snprintf(errBuf, sizeof(errBuf),
                 "fchmod(fd=%d, mode=%o) failed: %s (errno=%d)",
                 fd, mode, strerror(errno), errno);
        napi_throw_error(env, "FCHMOD_ERROR", errBuf);
        return nullptr;
    }

    napi_value result;
    napi_get_boolean(env, true, &result);
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
/*  spawnFromFd(fd, args, env?) — spawn via /proc/self/fd/<fd>         */
/*                                                                    */
/*  HarmonyOS sandbox paths are virtual — posix_spawn(path) fails.    */
/*  But an fd opened by ArkTS is a real kernel fd. On Linux,          */
/*  execve("/proc/self/fd/<fd>") works because the kernel uses        */
/*  the fd's inode directly, bypassing path resolution.               */
/* ------------------------------------------------------------------ */

static napi_value SpawnFromFd(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_status napiStatus = napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (napiStatus != napi_ok || argc < 2) {
        napi_throw_type_error(env, nullptr,
            "Expected 2-3 arguments: fd (number), args (string[]), [env (object)]");
        return nullptr;
    }

    /* --- Read fd --- */
    int32_t fd = -1;
    napi_get_value_int32(env, args[0], &fd);
    if (fd < 0) {
        napi_throw_type_error(env, nullptr, "fd must be a non-negative integer");
        return nullptr;
    }

    /* Verify fd is valid via fstat */
    struct stat fdStat;
    if (fstat(fd, &fdStat) != 0) {
        char errBuf[256];
        snprintf(errBuf, sizeof(errBuf),
                 "fstat(fd=%d) failed: %s", fd, strerror(errno));
        napi_throw_error(env, "FD_ERROR", errBuf);
        return nullptr;
    }

    /* Construct /proc/self/fd/<fd> path */
    char procFdPath[64];
    snprintf(procFdPath, sizeof(procFdPath), "/proc/self/fd/%d", fd);

    /* --- Read arguments array --- */
    bool isArray = false;
    napi_is_array(env, args[1], &isArray);
    if (!isArray) {
        napi_throw_type_error(env, nullptr, "args must be an array of strings");
        return nullptr;
    }

    uint32_t argCount = 0;
    napi_get_array_length(env, args[1], &argCount);

    /* Build argv: [procFdPath, arg0, arg1, ..., nullptr] */
    std::vector<std::string> argStrings;
    std::vector<char *> argv;

    argStrings.push_back(procFdPath);  /* argv[0] = program name */
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

    /* --- Spawn using /proc/self/fd/<fd> as the path --- */
    pid_t pid = 0;
    int ret = posix_spawn(&pid, procFdPath,
                           nullptr, nullptr, argv.data(), envp.data());

    if (ret != 0) {
        char errBuf[512];
        snprintf(errBuf, sizeof(errBuf),
                 "posix_spawn(/proc/self/fd/%d) failed: %s (errno=%d, "
                 "fdStat: mode=%o size=%lld)",
                 fd, strerror(ret), ret,
                 fdStat.st_mode, (long long)fdStat.st_size);
        napi_throw_error(env, "SPAWN_ERROR", errBuf);
        return nullptr;
    }

    napi_value pidValue;
    napi_create_int32(env, pid, &pidValue);
    return pidValue;
}

/* ------------------------------------------------------------------ */
/*  spawnFromMemfd(srcFd, args, env?) — copy binary to memfd,          */
/*  then spawn from /proc/self/fd/<memfd> or execveat                  */
/*                                                                    */
/*  HarmonyOS mounts app sandbox dirs with noexec — posix_spawn       */
/*  returns EPERM/EACCES. memfd_create allocates in tmpfs (RAM).      */
/*  We explicitly request MFD_EXEC (Linux 6.3+) and try both          */
/*  posix_spawn and fork()+execveat(AT_EMPTY_PATH) to bypass          */
/*  the noexec restriction.                                           */
/* ------------------------------------------------------------------ */

/* MFD_EXEC flag — added in Linux 6.3 to explicitly allow exec */
#ifndef MFD_EXEC
#define MFD_EXEC 0x0010U
#endif

/* execveat syscall number on aarch64 */
#ifndef __NR_execveat
#define __NR_execveat 281
#endif

/* AT_EMPTY_PATH for execveat */
#ifndef AT_EMPTY_PATH
#define AT_EMPTY_PATH 0x1000
#endif

/* __NR_execve on aarch64 */
#ifndef __NR_execve
#define __NR_execve 221
#endif

static napi_value SpawnFromMemfd(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_status napiStatus = napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (napiStatus != napi_ok || argc < 2) {
        napi_throw_type_error(env, nullptr,
            "Expected 2-3 arguments: srcFd (number), args (string[]), [env (object)]");
        return nullptr;
    }

    /* --- Read source fd --- */
    int32_t srcFd = -1;
    napi_get_value_int32(env, args[0], &srcFd);
    if (srcFd < 0) {
        napi_throw_type_error(env, nullptr, "srcFd must be a non-negative integer");
        return nullptr;
    }

    /* Get source file size via fstat */
    struct stat srcStat;
    if (fstat(srcFd, &srcStat) != 0) {
        char errBuf[256];
        snprintf(errBuf, sizeof(errBuf),
                 "fstat(srcFd=%d) failed: %s", srcFd, strerror(errno));
        napi_throw_error(env, "FD_ERROR", errBuf);
        return nullptr;
    }
    size_t fileSize = srcStat.st_size;

    /* --- Read ELF interpreter from source binary --- */
    char interpreter[512] = {0};
    {
        Elf64_Ehdr ehdr;
        ssize_t nread = pread(srcFd, &ehdr, sizeof(ehdr), 0);
        if (nread == (ssize_t)sizeof(ehdr)) {
            Elf64_Phdr phdr;
            for (int i = 0; i < ehdr.e_phnum; i++) {
                nread = pread(srcFd, &phdr, sizeof(phdr),
                              ehdr.e_phoff + i * sizeof(Elf64_Phdr));
                if (nread != (ssize_t)sizeof(phdr)) break;
                if (phdr.p_type == PT_INTERP) {
                    size_t plen = phdr.p_filesz < sizeof(interpreter)
                        ? phdr.p_filesz : sizeof(interpreter) - 1;
                    pread(srcFd, interpreter, plen, phdr.p_offset);
                    break;
                }
            }
        }
    }

    /* --- Read /proc/sys/vm/memfd_noexec for diagnostics --- */
    int memfdNoexecVal = -1;
    {
        int nfd = open("/proc/sys/vm/memfd_noexec", O_RDONLY);
        if (nfd >= 0) {
            char nbuf[16];
            ssize_t n = read(nfd, nbuf, sizeof(nbuf) - 1);
            if (n > 0) {
                nbuf[n] = '\0';
                memfdNoexecVal = atoi(nbuf);
            }
            close(nfd);
        }
    }

    /*
     * --- Create memfd WITHOUT MFD_CLOEXEC ---
     *
     * We deliberately do NOT set MFD_CLOEXEC because the memfd must
     * survive execve() so the dynamic linker can access it via
     * /proc/self/fd/<memfd>.
     *
     * We DO set MFD_EXEC to explicitly request execution permission
     * (needed when vm.memfd_noexec=1).
     */
    int memFd = syscall(__NR_memfd_create, "node_bin", MFD_EXEC);
    if (memFd < 0 && (errno == EINVAL || errno == ENOSYS)) {
        /* MFD_EXEC not supported (pre-6.3 kernel), try with no flags */
        memFd = syscall(__NR_memfd_create, "node_bin", 0);
    }
    if (memFd < 0) {
        char errBuf[256];
        snprintf(errBuf, sizeof(errBuf),
                 "memfd_create failed: %s (errno=%d, memfd_noexec=%d)",
                 strerror(errno), errno, memfdNoexecVal);
        napi_throw_error(env, "MEMFD_ERROR", errBuf);
        return nullptr;
    }

    /* --- Copy binary from srcFd to memFd in chunks --- */
    const size_t CHUNK = 4 * 1024 * 1024;  /* 4MB */
    std::vector<char> buf(CHUNK);
    size_t remaining = fileSize;
    off_t offset = 0;

    while (remaining > 0) {
        size_t toRead = (remaining < CHUNK) ? remaining : CHUNK;
        ssize_t bytesRead = pread(srcFd, buf.data(), toRead, offset);
        if (bytesRead <= 0) {
            if (bytesRead < 0 && errno == EINTR) continue;
            char errBuf[256];
            snprintf(errBuf, sizeof(errBuf),
                     "pread failed at offset %lld: %s",
                     (long long)offset, strerror(errno));
            close(memFd);
            napi_throw_error(env, "COPY_ERROR", errBuf);
            return nullptr;
        }
        ssize_t bytesWritten = write(memFd, buf.data(), bytesRead);
        if (bytesWritten != bytesRead) {
            char errBuf[256];
            snprintf(errBuf, sizeof(errBuf),
                     "write to memfd failed: %s", strerror(errno));
            close(memFd);
            napi_throw_error(env, "COPY_ERROR", errBuf);
            return nullptr;
        }
        offset += bytesRead;
        remaining -= bytesRead;
    }

    /* Make memfd executable */
    fchmod(memFd, 0700);

    /* --- Read arguments array --- */
    bool isArray = false;
    napi_is_array(env, args[1], &isArray);
    if (!isArray) {
        napi_throw_type_error(env, nullptr, "args must be an array of strings");
        close(memFd);
        return nullptr;
    }

    uint32_t argCount = 0;
    napi_get_array_length(env, args[1], &argCount);

    /* Construct /proc/self/fd/<memfd> path */
    char procFdPath[64];
    snprintf(procFdPath, sizeof(procFdPath), "/proc/self/fd/%d", memFd);

    /* --- Build user args (from JavaScript) --- */
    std::vector<std::string> userArgs;
    for (uint32_t i = 0; i < argCount; i++) {
        napi_value elem;
        napi_get_element(env, args[1], i, &elem);
        size_t elemLen = 0;
        napi_get_value_string_utf8(env, elem, nullptr, 0, &elemLen);
        std::string argStr(elemLen + 1, '\0');
        napi_get_value_string_utf8(env, elem, &argStr[0], elemLen + 1, &elemLen);
        argStr.resize(elemLen);
        userArgs.push_back(std::move(argStr));
    }

    /* --- Build argv for Method 1: dynamic linker --- */
    /* ld-musl-aarch64.so.1 /proc/self/fd/<memfd> <userArgs...> */
    std::vector<std::string> linkerArgStrings;
    std::vector<char *> linkerArgv;
    if (interpreter[0]) {
        linkerArgStrings.push_back(interpreter);
        linkerArgv.push_back(&linkerArgStrings.back()[0]);
        linkerArgStrings.push_back(procFdPath);
        linkerArgv.push_back(&linkerArgStrings.back()[0]);
        for (const auto &a : userArgs) {
            linkerArgStrings.push_back(a);
            linkerArgv.push_back(&linkerArgStrings.back()[0]);
        }
    }
    linkerArgv.push_back(nullptr);

    /* --- Build argv for Method 2 & 3: direct exec --- */
    /* /proc/self/fd/<memfd> <userArgs...> */
    std::vector<std::string> directArgStrings;
    std::vector<char *> directArgv;
    directArgStrings.push_back(procFdPath);
    directArgv.push_back(&directArgStrings.back()[0]);
    for (const auto &a : userArgs) {
        directArgStrings.push_back(a);
        directArgv.push_back(&directArgStrings.back()[0]);
    }
    directArgv.push_back(nullptr);

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

    /*
     * --- Execution: fork() + three exec methods ---
     *
     * Method 1 (PRIMARY): execve(interpreter, [interpreter, /proc/self/fd/<memfd>, ...args], envp)
     *   The dynamic linker (ld-musl) is a system binary in /lib/ which IS
     *   executable. It loads the node binary via mmap(PROT_EXEC) — a
     *   different kernel code path than execve, potentially bypassing
     *   the noexec restriction on sandbox files.
     *   The memfd is NOT CLOEXEC so it survives execve and the linker
     *   can open it via /proc/self/fd/<memfd>.
     *
     * Method 2 (fallback): execveat(memFd, "", ..., AT_EMPTY_PATH)
     *   Direct exec from fd without path resolution.
     *
     * Method 3 (fallback): execve("/proc/self/fd/<memfd>", ..., ...)
     *   Exec from /proc/self/fd path.
     */
    int errPipe[2];
    if (pipe(errPipe) != 0) {
        char errBuf[256];
        snprintf(errBuf, sizeof(errBuf),
                 "pipe() failed: %s", strerror(errno));
        close(memFd);
        napi_throw_error(env, "SPAWN_ERROR", errBuf);
        return nullptr;
    }
    fcntl(errPipe[1], F_SETFD, FD_CLOEXEC);

    pid_t pid = fork();

    if (pid == 0) {
        /* === CHILD PROCESS === */
        close(errPipe[0]);

        int err;

        /* Method 1: Dynamic linker */
        if (interpreter[0]) {
            syscall(__NR_execve, interpreter,
                    linkerArgv.data(), envp.data());
            err = errno;
            write(errPipe[1], &err, sizeof(err));
        } else {
            err = ENOENT;
            write(errPipe[1], &err, sizeof(err));
        }

        /* Method 2: execveat with AT_EMPTY_PATH */
        syscall(__NR_execveat, memFd, "",
                directArgv.data(), envp.data(), AT_EMPTY_PATH);
        err = errno;
        write(errPipe[1], &err, sizeof(err));

        /* Method 3: execve /proc/self/fd/<memfd> */
        syscall(__NR_execve, procFdPath,
                directArgv.data(), envp.data());
        err = errno;
        write(errPipe[1], &err, sizeof(err));

        _exit(127);
    }

    /* === PARENT PROCESS === */
    close(errPipe[1]);
    close(memFd);

    if (pid < 0) {
        close(errPipe[0]);
        char errBuf[512];
        snprintf(errBuf, sizeof(errBuf),
                 "fork() failed: %s (errno=%d)",
                 strerror(errno), errno);
        napi_throw_error(env, "SPAWN_ERROR", errBuf);
        return nullptr;
    }

    /* Read exec errors from child (3 possible, one per method) */
    int errs[3] = {0, 0, 0};
    ssize_t totalRead = 0;
    while (totalRead < (ssize_t)sizeof(errs)) {
        ssize_t n = read(errPipe[0], (char *)errs + totalRead,
                         sizeof(errs) - totalRead);
        if (n <= 0) break;  /* EOF or error */
        totalRead += n;
    }
    close(errPipe[0]);

    int numErrs = (int)(totalRead / sizeof(int));

    if (numErrs == 0) {
        /* EOF immediately = Method 1 (dynamic linker) succeeded */
    } else if (numErrs == 1) {
        /* Method 1 failed, Method 2 (execveat) succeeded */
    } else if (numErrs == 2) {
        /* Methods 1 & 2 failed, Method 3 (execve) succeeded */
    } else {
        /* All 3 methods failed */
        char errBuf[768];
        snprintf(errBuf, sizeof(errBuf),
                 "All exec methods failed [memfd_noexec=%d, interpreter=%s]:\n"
                 "  1. linker execve errno=%d (%s)\n"
                 "  2. execveat errno=%d (%s)\n"
                 "  3. execve(/proc/self/fd) errno=%d (%s)",
                 memfdNoexecVal,
                 interpreter[0] ? interpreter : "(none)",
                 errs[0], strerror(errs[0]),
                 errs[1], strerror(errs[1]),
                 errs[2], strerror(errs[2]));
        napi_throw_error(env, "SPAWN_ERROR", errBuf);
        return nullptr;
    }

    napi_value pidValue;
    napi_create_int32(env, pid, &pidValue);
    return pidValue;
}

/* ------------------------------------------------------------------ */
/*  diagnoseFd(fd) — read ELF header from an open fd                   */
/* ------------------------------------------------------------------ */

static napi_value DiagnoseFd(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t fd = -1;
    napi_get_value_int32(env, args[0], &fd);

    napi_value result;
    napi_create_object(env, &result);
    napi_value val;

    /* fstat via fd */
    struct stat st;
    char statBuf[256];
    if (fstat(fd, &st) == 0) {
        snprintf(statBuf, sizeof(statBuf), "mode=%o size=%lld uid=%d gid=%d",
                 st.st_mode, (long long)st.st_size, st.st_uid, st.st_gid);
        napi_get_boolean(env, true, &val);
    } else {
        snprintf(statBuf, sizeof(statBuf), "fstat failed: %s", strerror(errno));
        napi_get_boolean(env, false, &val);
    }
    napi_set_named_property(env, result, "fdValid", val);
    napi_create_string_utf8(env, statBuf, NAPI_AUTO_LENGTH, &val);
    napi_set_named_property(env, result, "stat", val);

    /* Read ELF header via pread (doesn't need path) */
    char interpBuf[512] = {0};
    char magicBuf[256] = {0};

    unsigned char magic[4];
    ssize_t nread = pread(fd, magic, 4, 0);
    if (nread == 4) {
        snprintf(magicBuf, sizeof(magicBuf),
                 "0x%02x 0x%02x 0x%02x 0x%02x%s",
                 magic[0], magic[1], magic[2], magic[3],
                 (magic[0] == 0x7f && magic[1] == 'E' &&
                  magic[2] == 'L' && magic[3] == 'F')
                     ? " (ELF!)" : " (NOT ELF)");
    } else {
        snprintf(magicBuf, sizeof(magicBuf),
                 "pread failed: %s (nread=%zd)", strerror(errno), nread);
    }
    napi_create_string_utf8(env, magicBuf, NAPI_AUTO_LENGTH, &val);
    napi_set_named_property(env, result, "magic", val);

    /* Read full ELF header to find PT_INTERP */
    Elf64_Ehdr ehdr;
    nread = pread(fd, &ehdr, sizeof(ehdr), 0);
    if (nread == sizeof(ehdr)) {
        Elf64_Phdr phdr;
        for (int i = 0; i < ehdr.e_phnum; i++) {
            nread = pread(fd, &phdr, sizeof(phdr),
                          ehdr.e_phoff + i * sizeof(Elf64_Phdr));
            if (nread != sizeof(phdr)) break;
            if (phdr.p_type == PT_INTERP) {
                pread(fd, interpBuf,
                      phdr.p_filesz < sizeof(interpBuf)
                          ? phdr.p_filesz : sizeof(interpBuf) - 1,
                      phdr.p_offset);
                break;
            }
        }
    }

    napi_create_string_utf8(env, interpBuf[0] ? interpBuf : "(none)",
                            NAPI_AUTO_LENGTH, &val);
    napi_set_named_property(env, result, "interpreter", val);

    if (interpBuf[0]) {
        napi_get_boolean(env, access(interpBuf, F_OK) == 0, &val);
    } else {
        napi_get_boolean(env, false, &val);
    }
    napi_set_named_property(env, result, "interpreterExists", val);

    /* readlink /proc/self/fd/<fd> */
    char procPath[64];
    snprintf(procPath, sizeof(procPath), "/proc/self/fd/%d", fd);
    char realBuf[4096] = {0};
    ssize_t len = readlink(procPath, realBuf, sizeof(realBuf) - 1);
    if (len < 0) {
        snprintf(realBuf, sizeof(realBuf), "readlink failed: %s", strerror(errno));
    }
    napi_create_string_utf8(env, realBuf, NAPI_AUTO_LENGTH, &val);
    napi_set_named_property(env, result, "fdPath", val);

    /* Try access() on the fdPath */
    napi_get_boolean(env, access(realBuf, F_OK) == 0, &val);
    napi_set_named_property(env, result, "fdPathAccessible", val);

    return result;
}

/* ------------------------------------------------------------------ */
/*  checkAccessiblePaths() — find what directories NAPI can access     */
/* ------------------------------------------------------------------ */

static napi_value CheckAccessiblePaths(napi_env env, napi_callback_info info) {
    napi_value result;
    napi_create_array(env, &result);

    const char *paths[] = {
        "/",
        "/data",
        "/data/local",
        "/data/local/tmp",
        "/tmp",
        "/proc",
        "/proc/self",
        "/proc/self/fd",
        "/proc/self/cwd",
        "/system",
        "/system/bin",
        "/dev",
        "/dev/null",
        nullptr
    };

    uint32_t idx = 0;
    for (int i = 0; paths[i] != nullptr; i++) {
        napi_value entry;
        napi_create_object(env, &entry);

        napi_value pathVal;
        napi_create_string_utf8(env, paths[i], NAPI_AUTO_LENGTH, &pathVal);
        napi_set_named_property(env, entry, "path", pathVal);

        /* Check access */
        napi_value existsVal, execVal;
        napi_get_boolean(env, access(paths[i], F_OK) == 0, &existsVal);
        napi_get_boolean(env, access(paths[i], X_OK) == 0, &execVal);
        napi_set_named_property(env, entry, "exists", existsVal);
        napi_set_named_property(env, entry, "executable", execVal);

        /* Check stat */
        struct stat st;
        char statBuf[128];
        if (stat(paths[i], &st) == 0) {
            snprintf(statBuf, sizeof(statBuf), "mode=%o uid=%d gid=%d",
                     st.st_mode, st.st_uid, st.st_gid);
        } else {
            snprintf(statBuf, sizeof(statBuf), "%s", strerror(errno));
        }
        napi_value statVal;
        napi_create_string_utf8(env, statBuf, NAPI_AUTO_LENGTH, &statVal);
        napi_set_named_property(env, entry, "stat", statVal);

        napi_set_element(env, result, idx++, entry);
    }

    return result;
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
{"fchmodFd",     nullptr, FchmodFd,     nullptr, nullptr, nullptr,
napi_default, nullptr},
        {"diagnose",     nullptr, Diagnose,     nullptr, nullptr, nullptr,
            napi_default, nullptr},
        {"resolveFd",    nullptr, ResolveFd,    nullptr, nullptr, nullptr,
            napi_default, nullptr},
        {"spawnFromFd",  nullptr, SpawnFromFd,  nullptr, nullptr, nullptr,
            napi_default, nullptr},
        {"spawnFromMemfd", nullptr, SpawnFromMemfd, nullptr, nullptr, nullptr,
            napi_default, nullptr},
        {"diagnoseFd",   nullptr, DiagnoseFd,   nullptr, nullptr, nullptr,
            napi_default, nullptr},
        {"checkPaths",   nullptr, CheckAccessiblePaths, nullptr, nullptr, nullptr,
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
