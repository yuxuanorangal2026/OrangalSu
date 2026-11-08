# OrangalSu

面向 **科大讯飞 T20 学习机**（Android 9 / API 28 / 展讯平台 / system-as-root 待判定）的系统级 root 方案：
自带 ramdisk 注入器、常驻 root 守护进程、Magisk 风格 systemless 模块加载，以及一套纯原生 View 实现的「液态玻璃」管理端 App。

* 包名：`com.orangal.su`
* 当前版本：**v2.4.53 / versionCode 62**
* 签名：`CN=OrangalSu`，证书 DER 的 SHA-256 = `056bcc0b927386e9bc350faa82678a944e9f59ac456afeb0bd2dd8940eb04e26`

---

## 一、目录结构

```
orangalsu/
├── build.sh                  # 一键构建：native → assets → aapt2 → javac/kotlinc → d8 → apksigner → zip
├── ecj.jar                   # ECJ，用于构建前的 Java 语法预检
├── native/                   # 全部 C 源码与 ramdisk 脚本
│   ├── common.h              # 公共定义、字符串异或混淆 deob()、日志
│   ├── orangalsud.c          # root 守护进程（su/ctl/notify 三个 socket + 模块挂载 + 隐藏）
│   ├── su.c                  # su 客户端（shim，连接守护进程）
│   ├── bootpatch.c           # boot.img 解析 / ramdisk cpio 打包 / init.rc 注入 / AVB 签名
│   ├── kpatchload.c          # KPM 内核补丁加载
│   ├── tinyinit.c            # ramdisk 内的最小 init 兜底
│   ├── sha256.c / bignum.c   # SHA-1/256、RSA（AVB 签名用）
│   ├── init.orangalsu.rc     # 注入 ramdisk 的 init 脚本
│   ├── firstboot.sh          # post-fs-data 首启脚本（部署二进制、模块挂载）
│   ├── module_mount.sh       # systemless 模块挂载（Magisk 兼容）
│   └── watchdog.sh           # 旧版保活脚本（v2.4.51 起不再使用，保留备查）
├── app/
│   ├── AndroidManifest.xml
│   ├── res/
│   ├── libs/kotlin-stdlib.jar
│   ├── assets/
│   │   ├── bin/{arm64-v8a,armeabi-v7a}/   # 构建产物（native 编译输出，不入库）
│   │   ├── magisk_res/                   # magisk.xz / stub.xz / init-ld.xz（构建时生成）
│   │   ├── init.orangalsu.rc / firstboot.sh / module_mount.sh
│   └── src/
│       ├── com/orangal/su/               # Java 主体
│       │   ├── App.java                  # Application，自校验 + 二进制解包
│       │   ├── MainActivity.java         # 4 tab 主界面（状态/授权/模块/设置）
│       │   ├── BootPatchActivity.java    # boot 修补流程
│       │   ├── GrantActivity.java        # 授权弹窗
│       │   ├── BootReceiver.java / ModuleInstallActivity.java
│       │   ├── activity/                 # 主题、字体、壁纸、隐藏列表、越狱、KPM 等子页
│       │   ├── core/
│       │   │   ├── Integrity.java        # v2.4.53 安装包自校验（包名 + 证书指纹）
│       │   │   ├── SuClient.java         # socket 客户端（SOCK_SU / SOCK_CTL / SOCK_NOTIFY）
│       │   │   ├── PolicyStore.java      # 授权库读写（ctl 优先，su 兜底，行式 upsert）
│       │   │   ├── DenyStore.java        # 隐藏列表
│       │   │   ├── NativeRunner.java     # 调用自带 su/bin 的命令执行封装
│       │   │   ├── RequestService.java   # 后台请求服务
│       │   │   └── ModuleManager.java / ZipGenerator.java / PassStore.java
│       │   ├── ui/                       # 液态玻璃组件（GlassCard / GlassTabBar / GlassLens …）
│       │   └── data/Prefs.java
│       └── kotlin/com/orangal/su/ui/liquid/   # Kotlin 版底栏与图标
└── out/                      # 构建产物（不入库）
```

---

## 二、构建

### 依赖

| 组件 | 路径（脚本内硬编码，按自己环境改） |
| --- | --- |
| Android SDK | `/home/user/android-sdk`（build-tools 30.0.3 / platforms android-28） |
| NDK | `/home/user/android-ndk-r23c` |
| 签名 | `/home/user/Doubao/chats/38449103130144514/release/{akey_pkcs8.der,acert.pem}` |
| zlib 源码 | `/tmp/zlib-src/zlib-1.2.13`（首次构建会自动编译成 `out/zlib{64,32}/libz.a`） |

### 命令

```bash
bash build.sh
```

流程共 7 步：zlib 静态库 → native（arm64 + armv7，全部 `-static`）→ assets → aapt2 编译/链接 →
javac + kotlinc → d8（生成 classes.dex）→ apksigner 签名 → 生成 flashable zip。
完整构建约 2.5–3 分钟，产物在 `out/`：

* `OrangalSu-<ver>.apk`
* `OrangalSu-flashable.zip`（内含 APK + `update-binary`，装到 `/system/app/OrangalSu`）

### 版本号同步（两处 + 5 处文件名）

`build.sh` 的 `--version-code` / `--version-name` 与 `app/AndroidManifest.xml` 的
`android:versionCode` / `android:versionName` 必须一致，否则 dex 与清单会对不上。

### 语法预检（可选，避免构建到一半才报错）

```bash
find app/src out/gen -name '*.java' > /tmp/srcs.txt
java -cp ecj.jar org.eclipse.jdt.internal.compiler.batch.Main \
  -source 1.8 -target 1.8 \
  -cp $ANDROID_JAR:app/libs/kotlin-stdlib.jar:out/kclasses \
  -d /tmp/cls @/tmp/srcs.txt          # 注意：必须带 out/kclasses，否则引用 Kotlin 组件会报错

aarch64-linux-android21-clang -fsyntax-only -O2 -I native native/orangalsud.c
```

---

## 三、运行架构

分三层，互相只通过 socket 通信：

```
┌─────────────── ramdisk（每次开机重建） ───────────────┐
│ init.orangalsu.rc → on post-fs-data:                  │
│     exec firstboot.sh   （部署二进制 + 模块挂载）      │
│ service orangalsu /system/xbin/orangalsud --daemon    │
│     class late_start / user root / seclabel u:r:su:s0 │
│     oneshot                                           │
└───────────────────────────────────────────────────────┘
                        │
                        ▼
        /data/adb/orangalsu/bin/orangalsud（常驻）
        su socket / ctl socket / notify socket
                        │
                        ▼
            App（管理系统、弹授权、读写策略、模块页）
```

### 三个 socket

| socket | 用途 | 鉴权 |
| --- | --- | --- |
| `orangalsu_su` | 执行 su 请求、`AUTHSELF` 自举、状态 ping | 任意进程可连，请求方 uid 决定策略 |
| `orangalsu_ctl` | 策略读写：PING / SETPOLICY / DELPOLICY / SETDEFAULT / HIDEADD / HIDEDEL / DECIDE / GETPOLICY / GETDENY / GETDEFAULT | `SO_PEERCRED`：uid==0 或 == 管理器 uid |
| `orangalsu_notify` | 弹授权窗的通路 | 单向通知 |

socket 名在 `common.h` 里是异或混淆的（`deob()` 用 `x[i] ^ (0xA5+i)`），避免被直接从二进制里 grep。

### daemon 启动流程（`orangalsud.c` main）

1. 只接受 `--daemon`，否则静默 `return 1`
2. `fork` + `setsid` 脱离调用者会话（父进程 `_exit(0)`，正好匹配 rc 的 `oneshot`）
3. `auto_grant_self()`：把自己的 uid 写进白名单
4. `prctl(PR_SET_NAME, "klogd")`：伪装进程名
5. `boot_extra()`：模块加载 / overlay / KPM
6. `boot_extra_when_data()`：若启动时 `/data` 还没就绪，起子进程轮询等待后补挂
7. 监听 su / ctl 两个 socket，`poll()` 循环分发连接（每个连接 fork 处理）

### 授权策略存储

`/data/adb/orangalsu/policy.db`，行式文本：

```
uid|mode|pkg|ts
```

* mode 只有两种：`allow` / `prompt`（"允许本次"不落盘）
* 写入走 `upsertLine`：sed 删旧行 → 追加 → `grep -c` 校验条数，**不做整表覆盖**（历史上整表写导致过“越用越空”）
* 读：ctl `GETPOLICY` → 失败则 `su cat` → 再兜底
* 默认策略被锁死为 `prompt`，App 启动时会纠正残留的 `allow`/`deny`
* 另存 `/data/adb/orangalsu/denylist`（隐藏列表）、`self.uid`（管理器 uid）

### 隐藏机制（`spawn()`）

对不受信进程执行 su 前的自我隔离：

1. `unshare(CLONE_NEWNS)` + `/` 设 `MS_PRIVATE`
2. `umount_module_binds()`：撤销模块 bind mount
3. tmpfs 覆盖 `/data/adb/orangalsu`、`/data/adb/magisk`
4. `0000` 空文件 bind 到 `/system/bin/su`、`/system/xbin/orangalsud`
5. `PATH` 不含自有 bin
6. 进程名 `klogd`

---

## 四、Magisk 模块加载

`module_mount.sh` 在 **post-fs-data** 阶段执行（早于 zygote / bootanim / system_server），扫描
`/data/adb/modules` **和** `/data/adb/orangalsu/modules` 两处：

1. 跳过 `disable` / `remove`，要求存在 `module.prop`
2. `chcon -R u:object_r:system_file:s0 <模块>/system`（源文件在 `/data`，上下文不对会被 avc 拒）
3. 逐文件映射：
   * `system/x` → `/system/x`（若检测到 `/system_root/system/build.prop` 则挂到 `/system_root/system/x`）
   * `system/vendor/x` → `/vendor/x`，`system/product/x` → `/product/x`，`system_ext` 同理
4. 目标不存在则记 `missing` 跳过；`mount --bind` 成功记 `ok`，失败记 `fail`
5. 执行模块的 `post-fs-data.sh`，后台拉起 `service.sh`
6. 全过程写 `/data/adb/orangalsu/module.log`

> 时序点：字体由 zygote 启动时读 `fonts.xml`、开机动画由 bootanim 加载 zip，所以**必须在 post-fs-data 完成挂载**，
> 任何放到 `late_start` 的挂载都来不及。这是 v2.4.46 之后反复调整的核心。

---

## 五、APK 自校验（v2.4.53）

`core/Integrity.java`：

* 包名必须等于 `com.orangal.su`
* 签名证书 DER 的 SHA-256 必须等于内置常量
* 双通道取样交叉校验：`GET_SIGNING_CERTIFICATES`（v2/v3）与 `GET_SIGNATURES`（v1），两者都要匹配且彼此一致

失败处理：`App.onCreate` 弹 Toast 说明原因后 2.5 秒自杀；`MainActivity.onCreate` 再兜一次，铺红字页面 4 秒后自杀。
换证书重签、改包名都会启动即退。

---

## 六、版本演进（近期）

| 版本 | 内容 |
| --- | --- |
| 2.4.38 | 定位“授权列表为空”根因：spawn 的 tmpfs 覆盖导致读侧永远空；加 ctl 读命令（GETPOLICY/GETDENY/GETDEFAULT） |
| 2.4.41 | 修整表覆盖 bug，改 upsertLine / deleteLine |
| 2.4.42–44 | 授权页诊断（AUTHSELF、ctl PING、条数、su exit）、主题反色 `adaptInk()`、`redeployDaemon()` |
| 2.4.45 | 授权列表改系统 ListView（后有“截断”问题） |
| 2.4.46 | 模块挂载提前 + SAR 目标根 + chcon，修字体/开机动画不生效 |
| 2.4.47 | 尝试 `--foreground` + init 托管（已被回退） |
| 2.4.48–51 | 回退到 `--daemon`，rc 反复调整为“不依赖 watchdog/额外文件” |
| 2.4.49 | 授权列表改回自有渲染（逐行 LinearLayout + 外层 ScrollView，解决截断） |
| 2.4.52 | module_mount 同时兼容 Magisk 与 OrangalSu 模块目录，日志化 |
| 2.4.53 | 安装包自校验（签名 + 包名），不符即拒绝启动 |

---

## 七、已知限制

* **Zygisk / LSPosed 未支持**：工程内零相关代码，需要在 zygote 注入 + Zygisk ABI 兼容层，尚未开工。
* **momo 仍可检出**：当前的 unshare/tmpfs 隐藏只覆盖部分探测面。
* `late_start` 的 rc 服务只负责起进程；**模块挂载必须由 firstboot 在 post-fs-data 完成**，两者不能混。
* 改 `init.orangalsu.rc` / `firstboot.sh` / `module_mount.sh` 后**必须重新修补 boot 并重启**，因为它们只存在于 ramdisk。
* `/system/bin/su` 在隐藏模式下被替换成空文件，终端里直接敲 `su` 会失败，正确入口是 `/data/adb/orangalsu/bin/su`。

---

## 八、签名与发布

```bash
# 验证签名
apksigner verify --print-certs out/OrangalSu-2.4.53.apk
# 期望：CN=OrangalSu，SHA-256 digest = 056bcc0b927386e9bc350faa82678a944e9f59ac456afeb0bd2dd8940eb04e26
```

* 私钥 `akey_pkcs8.der` / 证书 `acert.pem` **不在本仓库内**，在发布目录单独保存。
* 一旦更换签名或包名，必须同步修改 `Integrity.CERT_SHA256` / `Integrity.PKG`，否则 App 会拒绝启动。
