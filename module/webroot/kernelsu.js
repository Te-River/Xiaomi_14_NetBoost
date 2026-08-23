/*
 * Vendored from the official KernelSU WebUI library:
 *   https://github.com/tiann/KernelSU/blob/main/js/index.js
 * (MIT licensed, Copyright tiann / KernelSU contributors)
 *
 * Vendored (instead of `import { exec } from 'kernelsu'`) so the WebUI
 * works on every manager that injects the `ksu` Java bridge object,
 * including variants that do not resolve the bare module specifier.
 * Kept byte-equivalent in behavior; only this comment block is added.
 */
let callbackCounter = 0;
function getUniqueCallbackName(prefix) {
  return `${prefix}_callback_${Date.now()}_${callbackCounter++}`;
}
export function exec(command, options) {
  if (typeof options === "undefined") {
    options = {};
  }
  return new Promise((resolve, reject) => {
    // Generate a unique callback function name
    const callbackFuncName = getUniqueCallbackName("exec");
    // Define the success callback function
    window[callbackFuncName] = (errno, stdout, stderr) => {
      resolve({ errno, stdout, stderr });
      cleanup(callbackFuncName);
    };
    function cleanup(successName) {
      delete window[successName];
    }
    try {
      ksu.exec(command, JSON.stringify(options), callbackFuncName);
    } catch (error) {
      reject(error);
      cleanup(callbackFuncName);
    }
  });
}
export function toast(message) {
  ksu.toast(message);
}
