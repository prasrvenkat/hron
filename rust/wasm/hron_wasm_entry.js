/* @ts-self-types="./hron_wasm.d.ts" */

import * as imports from "./hron_wasm_bg.js";
import * as wasmModule from "./hron_wasm_bg.wasm";

if (typeof wasmModule.__wbindgen_start === "function") {
  // Bundler environment: the wasm import is already instantiated
  imports.__wbg_set_wasm(wasmModule);
  wasmModule.__wbindgen_start();
} else {
  // Cloudflare Workers / raw Module environment:
  // import of .wasm gives a WebAssembly.Module, not instantiated exports
  const mod = wasmModule.default ?? wasmModule;
  const instance = new WebAssembly.Instance(mod, {
    "./hron_wasm_bg.js": imports,
  });
  imports.__wbg_set_wasm(instance.exports);
  instance.exports.__wbindgen_start();
}

export { Schedule, fromCron } from "./hron_wasm_bg.js";
