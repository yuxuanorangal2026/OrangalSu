#!/bin/bash
# OrangalSu full build: native (arm64/armv7) -> assets -> aapt2 -> javac -> d8 -> apksigner
set -e
ROOT=/home/user/Doubao/chats/38449103130144514/orangalsu
SDK=/home/user/android-sdk
BT=$SDK/build-tools/30.0.3
PLATFORM=$SDK/platforms/android-28/android.jar
NDK=/home/user/android-ndk-r23c
TC=$NDK/toolchains/llvm/prebuilt/linux-x86_64
ZLIB=/tmp/zlib-src/zlib-1.2.13
OUT=$ROOT/out
mkdir -p $OUT

echo "== [1/7] zlib =="
if [ -f $OUT/zlib64/libz.a ] && [ -f $OUT/zlib32/libz.a ]; then
  echo "  zlib cached, skip"
else
for abi in aarch64 armv7; do
  case $abi in
    aarch64) CC=$TC/bin/aarch64-linux-android21-clang; LIBS=$OUT/zlib64;;
    armv7)   CC=$TC/bin/armv7a-linux-androideabi21-clang; LIBS=$OUT/zlib32;;
  esac
  mkdir -p $LIBS
  cd $ZLIB
  for src in adler32 crc32 deflate infback inffast inflate inftrees trees zutil compress uncompr; do
    $CC -O2 -I. -c $src.c -o $LIBS/$src.o
  done
  ar rcs $LIBS/libz.a $LIBS/*.o 2>/dev/null || llvm-ar rcs $LIBS/libz.a $LIBS/*.o
  echo "  $abi zlib OK"
done
fi

echo "== [2/7] native =="
for abi in aarch64 armv7; do
  case $abi in
    aarch64) CC=$TC/bin/aarch64-linux-android21-clang; Z=$OUT/zlib64/libz.a; DEST=$ROOT/app/assets/bin/arm64-v8a;;
    armv7)   CC=$TC/bin/armv7a-linux-androideabi21-clang; Z=$OUT/zlib32/libz.a; DEST=$ROOT/app/assets/bin/armeabi-v7a;;
  esac
  mkdir -p $DEST
  cd $ROOT/native
  $CC -O2 -fno-emulated-tls -static -I$ZLIB -o $DEST/bootpatch sha256.c bignum.c bootpatch.c $Z
  $CC -O2 -fno-emulated-tls -static -o $DEST/su su.c
  $CC -O2 -fno-emulated-tls -static -o $DEST/orangalsud orangalsud.c
  $CC -O2 -fno-emulated-tls -static -o $DEST/kpatchload kpatchload.c
  $CC -O2 -fno-emulated-tls -static -s -o $DEST/tinyinit tinyinit.c   # -s: strip（ramdisk 更小，腾出 AVB footer 空间）
  echo "  $abi binaries OK"
done
cp $ROOT/native/init.orangalsu.rc $ROOT/native/firstboot.sh $ROOT/native/module_mount.sh $ROOT/app/assets/
echo "  assets OK"

echo "  [aapt2] ="
build_once() {

rm -rf $OUT/compiled $OUT/gen $OUT/res.apk
mkdir -p $OUT/compiled $OUT/gen
$BT/aapt2 compile --dir $ROOT/app/res -o $OUT/compiled/
$BT/aapt2 link -o $OUT/res.apk -I $PLATFORM --manifest $ROOT/app/AndroidManifest.xml \
    --java $OUT/gen --min-sdk-version 28 --target-sdk-version 34 \
    --version-code 62 --version-name 2.4.53 $OUT/compiled/*.flat
echo "  aapt2 OK ($(ls $OUT/gen/com/orangal/su/R.java 2>/dev/null || echo 'NO R.JAVA'))"

echo "  [kotlin] ="
rm -rf $OUT/kclasses; mkdir -p $OUT/kclasses
KOTLINC=/home/user/kotlin-compiler/bin/kotlinc
if [ ! -x "$KOTLINC" ]; then echo "KOTLINC MISSING"; exit 1; fi
find $ROOT/app/src/kotlin -name '*.kt' > $OUT/kt.txt
$KOTLINC -no-reflect -jvm-target 1.8 -classpath $PLATFORM -d $OUT/kclasses @$OUT/kt.txt 2>$OUT/kotlinc.log || { echo "KOTLINC FAIL"; tail -40 $OUT/kotlinc.log; exit 1; }
echo "  kotlinc OK ($(find $OUT/kclasses -name '*.class' | wc -l) classes)"

echo "  [javac] ="
rm -rf $OUT/classes; mkdir -p $OUT/classes
find $ROOT/app/src $OUT/gen -name '*.java' > $OUT/sources.txt
java -cp $ROOT/ecj.jar org.eclipse.jdt.internal.compiler.batch.Main -source 1.8 -target 1.8 -cp $PLATFORM:$OUT/kclasses -d $OUT/classes @$OUT/sources.txt 2>$OUT/ecj.log || { echo "ECJ FAIL"; tail -40 $OUT/ecj.log; exit 1; }
echo "  javac OK ($(find $OUT/classes -name '*.class' | wc -l) classes)"

echo "  [d8] ="
rm -rf $OUT/dex; mkdir -p $OUT/dex
$BT/d8 --lib $PLATFORM --min-api 28 --release --output $OUT/dex $(find $OUT/classes $OUT/kclasses -name '*.class') $ROOT/app/libs/kotlin-stdlib.jar
echo "  d8 OK ($(ls $OUT/dex/))"

echo "  [package+sign] =="
rm -rf $OUT/apk $OUT/unsigned.apk $OUT/OrangalSu-2.4.53.apk
mkdir -p $OUT/apk
cd $OUT/apk
unzip -q $OUT/res.apk
cp $OUT/dex/classes.dex .
cp -r $ROOT/app/assets .
python3 - <<'EOF'
import zipfile, os
src='/home/user/Doubao/chats/38449103130144514/orangalsu/out/apk'
dst='/home/user/Doubao/chats/38449103130144514/orangalsu/out/unsigned.apk'
with zipfile.ZipFile(dst,'w',zipfile.ZIP_DEFLATED) as z:
    for root,dirs,files in os.walk(src):
        for f in files:
            p=os.path.join(root,f)
            z.write(p, os.path.relpath(p,src))
print('packed unsigned.apk')
EOF
KEYDIR=/home/user/Doubao/chats/38449103130144514/release
$BT/apksigner sign --key $KEYDIR/akey_pkcs8.der --cert $KEYDIR/acert.pem \
    --out $OUT/OrangalSu-2.4.53.apk $OUT/unsigned.apk
$BT/apksigner verify --print-certs $OUT/OrangalSu-2.4.53.apk | head -6
echo "  signed APK: $OUT/OrangalSu-2.4.53.apk"
}

# ============ two-pass build: pass1 APK -> stub.xz = pass1 APK xz -> pass2 final APK ============
# pass1 placeholder stub.xz MUST be empty (break recursion: pass1 apk has no shell,
# then stub.xz = pass1 apk xz, pass2 apk embeds it once)
for abi in arm64-v8a armeabi-v7a; do
  f=$ROOT/app/assets/magisk_res/$abi/stub.xz
  mkdir -p $(dirname $f)
  : > "$f"
done
build_once
echo "  [pass1 APK] -> xz shell stub.xz"
if command -v xz >/dev/null 2>&1; then
  xz -9fk "$OUT/OrangalSu-2.4.53.apk" -c > "$ROOT/app/assets/magisk_res/arm64-v8a/stub.xz.tmp"
  mv "$ROOT/app/assets/magisk_res/arm64-v8a/stub.xz.tmp" "$ROOT/app/assets/magisk_res/arm64-v8a/stub.xz"
  # stub 是 APK 壳，不依赖 ABI：只保留 arm64 一份
  rm -f "$ROOT/app/assets/magisk_res/armeabi-v7a/stub.xz"
else
  echo "  xz not found - keeping placeholder (stub will be empty)"; exit 1
fi
ls -l "$ROOT/app/assets/magisk_res/"*/stub.xz
build_once
echo "  [pass2 final APK OK]"

echo "== [7/7] flashable zip =="
rm -rf $OUT/flash; mkdir -p $OUT/flash/META-INF/com/google/android
cp $OUT/OrangalSu-2.4.53.apk $OUT/flash/OrangalSu.apk
cat > $OUT/flash/META-INF/com/google/android/update-binary <<'SH'
#!/sbin/sh
# OrangalSu recovery installer (TWRP / custom recovery, shell update-binary)
OUTFD=$2; ZIPFILE=$3
ui_print() { echo "ui_print $1"; echo "ui_print"; }
ui_print "OrangalSu installer"
ui_print "installing as system app..."
mount /system 2>/dev/null || true
mkdir -p /system/app/OrangalSu
if command -v unzip >/dev/null 2>&1; then
  unzip -o "$ZIPFILE" OrangalSu.apk -d /tmp/orangalsu >/dev/null 2>&1
  unzip -o "$ZIPFILE" boot.img -d /tmp/orangalsu >/dev/null 2>&1 || true
  cp -f /tmp/orangalsu/OrangalSu.apk /system/app/OrangalSu/OrangalSu.apk
else
  cp -f /system/app/OrangalSu/OrangalSu.apk /system/app/OrangalSu/OrangalSu.apk 2>/dev/null
fi
chmod 644 /system/app/OrangalSu/OrangalSu.apk
chcon u:object_r:system_file:s0 /system/app/OrangalSu/OrangalSu.apk 2>/dev/null || true
if [ -f /tmp/orangalsu/boot.img ] || ls /tmp/orangalsu/*.img >/dev/null 2>&1; then
  ui_print "flashing patched boot.img (optional)..."
  BOOTBLK=/dev/block/by-name/boot
  [ -b "$BOOTBLK" ] || BOOTBLK=$(ls /dev/block/platform/*/by-name/boot 2>/dev/null | head -1)
  [ -b "$BOOTBLK" ] || BOOTBLK=$(ls /dev/block/bootdevice/by-name/boot 2>/dev/null | head -1)
  if [ -b "$BOOTBLK" ]; then
    dd if=/tmp/orangalsu/boot.img of=$BOOTBLK bs=4096 2>/dev/null && ui_print "boot flashed"
  else
    ui_print "boot partition not found - skip"
  fi
fi
ui_print "done"
exit 0
SH
printf 'OrangalSu system-app installer (update-binary shell)\n' > $OUT/flash/META-INF/com/google/android/updater-script
echo "== [boot-sign] 可选：boot 镜像签名（BOOT_IN 或 out/boot_patched.img 存在时执行）=="
BOOT_IN="${BOOT_IN:-$ROOT/out/boot_patched.img}"
if [ -f "$BOOT_IN" ]; then
  python3 $ROOT/tools/avb_sign.py sign --image "$BOOT_IN" --key "$ROOT/app/assets/avb_keys_rsa4096_boot.pem" \
      --partition-size 36700160 --format old --release "avbtool 1.2.0 (OrangalSu)" --out $OUT/boot_signed.img
  python3 $ROOT/tools/avb_sign.py verify --image $OUT/boot_signed.img
  cp -f $OUT/boot_signed.img $OUT/flash/boot.img
  echo "  boot_signed.img 已并入 flashable zip（刷机时自动写入 boot 分区）"
else
  echo "  跳过：未提供 boot 镜像（设置 BOOT_IN=/path/boot.img 启用自动签名）"
fi
cd $OUT/flash && python3 - <<'EOF'
import zipfile, os
src='/home/user/Doubao/chats/38449103130144514/orangalsu/out/flash'
dst='/home/user/Doubao/chats/38449103130144514/orangalsu/out/OrangalSu-flashable.zip'
with zipfile.ZipFile(dst,'w',zipfile.ZIP_DEFLATED) as z:
    for root,dirs,files in os.walk(src):
        for f in files:
            p=os.path.join(root,f)
            z.write(p, os.path.relpath(p,src))
print('flashable zip:', dst)
EOF

echo "ALL DONE"
ls -la $OUT/OrangalSu-2.4.53.apk $OUT/OrangalSu-flashable.zip
