# 历史设计预览字体

这些字体仅供 `design-system/_archive-v1/previews/` 预览使用，不包含在 Dotist 应用中。这里的 WOFF2 文件是原字体的 GB2312 一级常用字子集。

- `LXGWNeoXiHei-GB1.woff2`：霞鹜新晰黑，由 [LXGW Neo XiHei](https://github.com/lxgw/LxgwNeoXiHei) 衍生，使用 [IPA Font License 1.0](IPA-FONT-LICENSE.md)。其原始授权字体是 IPAex Gothic。
- `LXGWNeoZhiSong-GB1.woff2`：霞鹜新致宋，由 [LXGW Neo ZhiSong](https://github.com/lxgw/LxgwNeoZhiSong) 衍生，使用 [IPA Font License 1.0](IPA-FONT-LICENSE.md)。其原始授权字体是 IPAex Mincho 或 IPAmj Mincho。
- `ZhuqueFangsong-GB1.woff2`：朱雀仿宋，由 [TrionesType](https://github.com/TrionesType/zhuque) 发布，使用 [SIL Open Font License 1.1](OFL-ZHUQUE.txt)。

如需将两个 IPA 衍生字体替换为原始授权字体，可从 [IPA 字体下载页面](https://moji.or.jp/ipafont/) 获取 IPAex Gothic 和 IPAex Mincho（或从同一机构获取 IPAmj Mincho），在预览 HTML 的 `@font-face` 中将相应 `src` 改为下载的原始字体文件并把 `format('woff2')` 改为 `format('truetype')`。这些预览文件可直接编辑，字体也可按上述路径单独替换。更完整的嵌入与替换说明见[字体作者的指南](https://github.com/lxgw/lxgw/blob/main/documents/xizhi_embedding_instructions.md)。
