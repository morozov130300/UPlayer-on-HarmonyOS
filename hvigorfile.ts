/*
 * UPlayer 根构建脚本
 *
 * 在系统 assembleApp 任务完成后，自动对产出的 signed .app 做无损压缩：
 * 仅把 zip 存储方式 STORED→DEFLATED(level 9)，条目内容逐字节不变，
 * 完整保留签名字段（extra），内层 hap 结构零改动 → 不影响签名与安装。
 * 压缩失败不会中断构建（仅打印错误）。
 */
import { appTasks } from '@ohos/hvigor-ohos-plugin';
import { hvigor } from '@ohos/hvigor';
import path from 'path';
import fs from 'fs';

function runCompress(): void {
  try {
    const outDir = path.join(__dirname, 'build', 'outputs', 'release');
    if (!fs.existsSync(outDir)) {
      return;
    }
    const apps = fs.readdirSync(outDir).filter((f: string) => f.endsWith('-signed.app'));
    if (apps.length === 0) {
      return;
    }
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    const { compressApp } = require(path.join(__dirname, 'hvigor', 'compress-app.js'));
    for (const name of apps) {
      const full = path.join(outDir, name);
      const r = compressApp(full);
      const saved = r.before - r.after;
      console.log(`[uplayer-compress] ${name}: ${r.before} -> ${r.after} B (saved ${saved}, ${((saved / r.before) * 100).toFixed(1)}%)`);
    }
  } catch (e) {
    console.error('[uplayer-compress] failed: ' + (e && e.message ? e.message : e));
  }
}

const compressAppPlugin = {
  pluginId: 'uplayer-compress-app',
  apply(node: any): void {
    node.afterNodeEvaluate(() => {
      try {
        const task = node.getTaskByName('assembleApp');
        if (task) {
          task.afterRun(() => runCompress());
        }
      } catch (e) {
        // 忽略：不同 hvigor 版本节点能力差异
      }
    });
  }
};

export default {
  system: appTasks, /* Built-in plugin of Hvigor. It cannot be modified. */
  plugins: [compressAppPlugin] /* Custom plugin to extend the functionality of Hvigor. */
}
