#!/bin/bash

# IPA重签名脚本
# 功能：对IPA包进行重签名，启用get-task-allow选项，并验证签名结果

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 打印信息函数
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# 检查参数
if [ $# -lt 2 ]; then
    echo "用法: $0 <IPA文件路径> <签名身份> [Provisioning Profile路径] [Bundle ID]"
    echo "示例: $0 app.ipa \"iPhone Developer: Your Name (XXXXXXXXXX)\" profile.mobileprovision com.example.app"
    echo ""
    echo "可用的签名身份列表："
    security find-identity -v -p codesigning
    exit 1
fi

IPA_PATH="$1"
SIGNING_IDENTITY="$2"
PROVISION_PROFILE="$3"
NEW_BUNDLE_ID="$4"

# 检查IPA文件是否存在
if [ ! -f "$IPA_PATH" ]; then
    print_error "IPA文件不存在: $IPA_PATH"
    exit 1
fi

# 检查签名身份是否有效
if ! security find-identity -v -p codesigning | grep -q "$SIGNING_IDENTITY"; then
    print_error "签名身份无效: $SIGNING_IDENTITY"
    echo ""
    echo "可用的签名身份列表："
    security find-identity -v -p codesigning
    exit 1
fi

print_info "开始重签名流程..."
print_info "IPA文件: $IPA_PATH"
print_info "签名身份: $SIGNING_IDENTITY"

# 创建临时工作目录
WORK_DIR=$(mktemp -d)
print_info "创建临时工作目录: $WORK_DIR"

# 清理函数
cleanup() {
    print_info "清理临时文件..."
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# 解压IPA
print_info "解压IPA包..."
unzip -q "$IPA_PATH" -d "$WORK_DIR"

# 查找Payload目录
PAYLOAD_DIR="$WORK_DIR/Payload"
if [ ! -d "$PAYLOAD_DIR" ]; then
    print_error "未找到Payload目录"
    exit 1
fi

# 查找.app文件
APP_PATH=$(find "$PAYLOAD_DIR" -name "*.app" -depth 1 | head -n 1)
if [ -z "$APP_PATH" ]; then
    print_error "未找到.app文件"
    exit 1
fi

APP_NAME=$(basename "$APP_PATH")
print_info "找到应用: $APP_NAME"

# 获取原始Bundle ID
INFO_PLIST="$APP_PATH/Info.plist"
ORIGINAL_BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print:CFBundleIdentifier' "$INFO_PLIST" 2>/dev/null)
print_info "原始Bundle ID: $ORIGINAL_BUNDLE_ID"

# 复制Provisioning Profile（如果提供）
if [ -n "$PROVISION_PROFILE" ] && [ -f "$PROVISION_PROFILE" ]; then
    print_info "复制Provisioning Profile..."
    cp "$PROVISION_PROFILE" "$APP_PATH/embedded.mobileprovision"
    
    # 如果未指定Bundle ID，尝试从Provisioning Profile提取
    if [ -z "$NEW_BUNDLE_ID" ]; then
        security cms -D -i "$PROVISION_PROFILE" > "$WORK_DIR/profile_temp.plist"
        PROFILE_APP_ID=$(/usr/libexec/PlistBuddy -c 'Print:Entitlements:application-identifier' "$WORK_DIR/profile_temp.plist" 2>/dev/null | sed 's/^[^.]*\.//')
        if [ -n "$PROFILE_APP_ID" ] && [ "$PROFILE_APP_ID" != "*" ]; then
            NEW_BUNDLE_ID="$PROFILE_APP_ID"
            print_info "从Provisioning Profile提取Bundle ID: $NEW_BUNDLE_ID"
        fi
    fi
fi

# 修改Bundle ID（如果提供了新的Bundle ID）
if [ -n "$NEW_BUNDLE_ID" ]; then
    print_info "修改Bundle ID为: $NEW_BUNDLE_ID"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $NEW_BUNDLE_ID" "$INFO_PLIST"
    
    # 同时更新其他相关标识符
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $(basename "$NEW_BUNDLE_ID")" "$INFO_PLIST" 2>/dev/null || true
else
    NEW_BUNDLE_ID="$ORIGINAL_BUNDLE_ID"
    print_warning "未指定新Bundle ID，使用原始Bundle ID: $NEW_BUNDLE_ID"
fi

# 创建entitlements.plist文件，启用get-task-allow
ENTITLEMENTS_PATH="$WORK_DIR/entitlements.plist"
print_info "创建Entitlements文件，启用get-task-allow..."

cat > "$ENTITLEMENTS_PATH" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>get-task-allow</key>
    <true/>
    <key>application-identifier</key>
    <string>*</string>
    <key>com.apple.developer.team-identifier</key>
    <string>*</string>
</dict>
</plist>
EOF

# 如果存在embedded.mobileprovision，从中提取entitlements
if [ -f "$APP_PATH/embedded.mobileprovision" ]; then
    print_info "从Provisioning Profile提取entitlements..."
    security cms -D -i "$APP_PATH/embedded.mobileprovision" > "$WORK_DIR/provision.plist"
    /usr/libexec/PlistBuddy -x -c 'Print:Entitlements' "$WORK_DIR/provision.plist" > "$ENTITLEMENTS_PATH" 2>/dev/null || true
    
    # 确保get-task-allow被设置为true
    /usr/libexec/PlistBuddy -c "Set :get-task-allow true" "$ENTITLEMENTS_PATH" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :get-task-allow bool true" "$ENTITLEMENTS_PATH" 2>/dev/null || true
    
    # 更新application-identifier以匹配新的Bundle ID
    TEAM_ID=$(/usr/libexec/PlistBuddy -c 'Print:Entitlements:com.apple.developer.team-identifier' "$WORK_DIR/provision.plist" 2>/dev/null)
    if [ -n "$TEAM_ID" ] && [ "$TEAM_ID" != "*" ]; then
        /usr/libexec/PlistBuddy -c "Set :application-identifier $TEAM_ID.$NEW_BUNDLE_ID" "$ENTITLEMENTS_PATH" 2>/dev/null || true
        print_info "更新application-identifier: $TEAM_ID.$NEW_BUNDLE_ID"
    fi
fi

# 删除旧的签名
print_info "删除现有签名..."
rm -rf "$APP_PATH/_CodeSignature" 2>/dev/null || true
rm -f "$APP_PATH/embedded.mobileprovision.old" 2>/dev/null || true

# 对所有Framework和Dylib进行签名
print_info "对Frameworks和动态库进行签名..."
find "$APP_PATH/Frameworks" -type f \( -name "*.dylib" -o -name "*.framework" \) 2>/dev/null | while read framework; do
    if [ -f "$framework" ]; then
        print_info "  签名: $(basename "$framework")"
        /usr/bin/codesign -f -s "$SIGNING_IDENTITY" "$framework" 2>/dev/null || true
    fi
done

# 对.framework目录中的可执行文件签名
find "$APP_PATH/Frameworks" -name "*.framework" 2>/dev/null | while read framework; do
    framework_executable=$(basename "$framework" .framework)
    if [ -f "$framework/$framework_executable" ]; then
        print_info "  签名Framework可执行文件: $framework_executable"
        /usr/bin/codesign -f -s "$SIGNING_IDENTITY" "$framework/$framework_executable" 2>/dev/null || true
    fi
done

# 对PlugIns进行签名
if [ -d "$APP_PATH/PlugIns" ]; then
    print_info "对PlugIns进行签名..."
    find "$APP_PATH/PlugIns" -name "*.appex" | while read plugin; do
        print_info "  签名: $(basename "$plugin")"
        /usr/bin/codesign -f -s "$SIGNING_IDENTITY" --entitlements "$ENTITLEMENTS_PATH" "$plugin"
    done
fi

# 对主应用进行签名
print_info "对主应用进行签名..."
/usr/bin/codesign -f -s "$SIGNING_IDENTITY" \
    --entitlements "$ENTITLEMENTS_PATH" \
    "$APP_PATH"

if [ $? -ne 0 ]; then
    print_error "签名失败"
    exit 1
fi

print_info "签名完成！"

# 验证签名
print_info "验证签名..."
echo ""
echo "========== 签名验证结果 =========="

# 验证主应用签名
codesign -vv -d "$APP_PATH" 2>&1
VERIFY_RESULT=$?

echo ""
echo "========== Entitlements内容 =========="
codesign -d --entitlements :- "$APP_PATH" 2>/dev/null

echo ""
echo "========== 签名详细信息 =========="
codesign -dvvv "$APP_PATH" 2>&1

# 检查get-task-allow是否已启用
echo ""
echo "========== 检查get-task-allow =========="
if codesign -d --entitlements :- "$APP_PATH" 2>/dev/null | grep -q "<key>get-task-allow</key>"; then
    if codesign -d --entitlements :- "$APP_PATH" 2>/dev/null | grep -A1 "<key>get-task-allow</key>" | grep -q "<true/>"; then
        print_info "✓ get-task-allow 已成功启用"
    else
        print_warning "✗ get-task-allow 未启用"
    fi
else
    print_warning "✗ get-task-allow 未找到"
fi

# 验证Bundle ID
echo ""
echo "========== Bundle ID 信息 =========="
FINAL_BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print:CFBundleIdentifier' "$INFO_PLIST" 2>/dev/null)
print_info "当前Bundle ID: $FINAL_BUNDLE_ID"
if [ "$FINAL_BUNDLE_ID" = "$NEW_BUNDLE_ID" ]; then
    print_info "✓ Bundle ID 已正确设置"
else
    print_warning "✗ Bundle ID 不匹配"
fi

if [ $VERIFY_RESULT -eq 0 ]; then
    print_info "✓ 签名验证通过"
else
    print_error "✗ 签名验证失败"
    exit 1
fi

# 重新打包IPA
print_info "重新打包IPA..."
# 获取IPA文件的绝对路径和目录
IPA_DIR=$(cd "$(dirname "$IPA_PATH")" && pwd)
IPA_BASENAME=$(basename "$IPA_PATH" .ipa)
OUTPUT_IPA="$IPA_DIR/${IPA_BASENAME}_resigned.ipa"

print_info "输出路径: $OUTPUT_IPA"

cd "$WORK_DIR"
zip -qr "$OUTPUT_IPA" Payload

print_info "重签名完成！"
print_info "输出文件: $OUTPUT_IPA"

echo ""
print_info "========== 最终验证 =========="
# 解压并验证新的IPA
VERIFY_DIR=$(mktemp -d)
unzip -q "$OUTPUT_IPA" -d "$VERIFY_DIR"
VERIFY_APP=$(find "$VERIFY_DIR/Payload" -name "*.app" -depth 1 | head -n 1)

codesign -vv "$VERIFY_APP" 2>&1
FINAL_VERIFY=$?

rm -rf "$VERIFY_DIR"

if [ $FINAL_VERIFY -eq 0 ]; then
    print_info "✓ 最终签名验证通过"
    echo ""
    print_info "重签名成功！可以使用以下文件:"
    print_info "  $OUTPUT_IPA"
else
    print_error "✗ 最终签名验证失败"
    exit 1
fi
