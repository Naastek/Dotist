# CloudKit 与 Android：后续研究

CloudKit 仍是同步候选。当前不连接账户、不创建容器、token 或密钥，也不传输任务。

Apple 提供 CloudKit JS 和 Web Services，可让网页访问 CloudKit 公共及私人数据库，但这不等同于一个已经验证可行的 Android 原生同步方案。Android 上的登录、token 生命周期、网络恢复、变更游标、冲突和后台同步仍须真实设备验证。Web Services 文档的部分内容是归档文档，实施前须重新确认现行支持。

参考：
- https://developer.apple.com/documentation/cloudkitjs
- https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/SettingUpWebServices.html

后续接入需用户单独确认账号和授权。同步仅通过一个明确选择的主后端进行；本地 outbox 目前只是保存变更，不执行上传或合并。
