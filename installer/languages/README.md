# installer/languages

`ChineseSimplified.isl` 是 Inno Setup 的**社区中文翻译** —— 官方 Inno Setup 安装包并不包含中文。

- 来源：Inno Setup 用户翻译页 <https://jrsoftware.org/files/istrans/>；维护者 Zhenghan Yang (Kira)，
  仓库 <https://github.com/kira-96/Inno-Setup-Chinese-Simplified-Translation>
- 文件头标注：`Inno Setup version 6.5.0+ Chinese Simplified messages`，编码 UTF-8（无 BOM）
- 本仓库中的副本取自 Inno Setup 7 安装目录的 `Languages\ChineseSimplified.isl`，SHA-256：
  `e0b0b350e2245f3c5e65586dfe43d574f6e7f06f2261149aba284954b3fc9a8d`

## 为什么放在这里

`installer/pure_music.iss` 通过 `MessagesFile: "compiler:Languages\ChineseSimplified.isl"` 引用编译器安装目录里的这份翻译。
本机装过该文件的机器可以直接编译，但 **CI 与其它干净环境没有这个文件**（官方 Inno Setup 不含中文），
Inno Setup 会直接报 `Couldn't open include file ... ChineseSimplified.isl` 并中止编译。

因此 `.github/workflows/build-windows-release.yml` 在调用 `ISCC.exe` 之前，会把这里的副本拷进 ISCC 的语言目录，
让本机与 CI 使用同一份翻译。本仓库暂不改动 `.iss` 的引用方式，以免影响既有的本机构建流程；
如果希望仓库完全自包含（不依赖编译器目录），可以把 `.iss` 改成相对路径引用本文件 —— Inno Setup 的相对路径按脚本所在目录解析。
