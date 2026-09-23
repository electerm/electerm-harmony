"use strict";
/**
 * Copyright (c) 2017, Daniel Imms (MIT License).
 * Copyright (c) 2018, Microsoft Corporation (MIT License).
 *
 * electerm-harmony / OHOS: `loadNativeModule('pty')` is short-circuited to the
 * application native library addressed by ELECTERM_PTY_ADDON (exported by
 * entry/src/main/cpp/node_ctl.c). OHOS refuses to map native code out of the
 * HAP's resources/resfile tree, so the addon has to be loaded from the app's
 * libs dir instead of node-pty's own build/Release path.
 */
Object.defineProperty(exports, "__esModule", { value: true });
exports.assign = assign;
exports.loadNativeModule = loadNativeModule;
function assign(target) {
    var sources = [];
    for (var _i = 1; _i < arguments.length; _i++) {
        sources[_i - 1] = arguments[_i];
    }
    sources.forEach(function (source) { return Object.keys(source).forEach(function (key) { return target[key] = source[key]; }); });
    return target;
}
function loadNativeModule(name) {
    // OHOS: see the note above. Only 'pty' is redirected — anything else
    // (conpty, spawn-helper …) keeps the normal lookup.
    if (name === 'pty' && process.env.ELECTERM_PTY_ADDON) {
        return {
            dir: require("path").dirname(process.env.ELECTERM_PTY_ADDON),
            module: require(process.env.ELECTERM_PTY_ADDON)
        };
    }
    // Check build, debug, and then prebuilds.
    var dirs = ['build/Release', 'build/Debug', "prebuilds/".concat(process.platform, "-").concat(process.arch)];
    // Check relative to the parent dir for unbundled and then the current dir for bundled
    var relative = ['..', '.'];
    var lastError;
    for (var _i = 0, dirs_1 = dirs; _i < dirs_1.length; _i++) {
        var d = dirs_1[_i];
        for (var _a = 0, relative_1 = relative; _a < relative_1.length; _a++) {
            var r = relative_1[_a];
            var dir = "".concat(r, "/").concat(d);
            try {
                return { dir: dir, module: require("".concat(dir, "/").concat(name, ".node")) };
            }
            catch (e) {
                lastError = e;
            }
        }
    }
    throw new Error("Failed to load native module: ".concat(name, ".node, checked: ").concat(dirs.join(', '), ": ").concat(lastError));
}
//# sourceMappingURL=utils.js.map
