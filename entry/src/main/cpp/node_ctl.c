/**
 * node_ctl.c — tiny NAPI module used by the ArkTS main process to control
 * the Node.js child process (currently: terminate it by pid).
 *
 * Import from ArkTS with:
 *   import nodeCtl from 'libnode_ctl.so'
 *
 * Kept in a separate .so from node_launcher.c: that library is loaded into
 * the native child process (which has no ArkTS/NAPI runtime), so it must
 * not have undefined NAPI symbols.
 */
#include "napi/native_api.h"
#include <signal.h>
#include <unistd.h>

static napi_value KillNode(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1];
  napi_get_cb_info(env, info, &argc, args, NULL, NULL);

  int32_t pid = -1;
  if (argc >= 1) {
    napi_get_value_int32(env, args[0], &pid);
  }
  int32_t result = -1;
  if (pid > 1) {
    /* TERM first so express can close listening sockets cleanly; KILL if it
     * survives. */
    result = kill((pid_t)pid, SIGTERM);
    if (result == 0) {
      usleep(200 * 1000); /* 200ms grace */
      kill((pid_t)pid, SIGKILL);
    }
  }
  napi_value napiResult = NULL;
  napi_create_int32(env, result, &napiResult);
  return napiResult;
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
  napi_property_descriptor desc[] = {
      {"killNode", NULL, KillNode, NULL, NULL, NULL, napi_default, NULL}};
  napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
  return exports;
}
EXTERN_C_END

static napi_module demoModule = {
    1, 0, NULL, Init, "node_ctl", NULL, {0}};

__attribute__((constructor)) void RegisterModule(void) {
  napi_module_register(&demoModule);
}
