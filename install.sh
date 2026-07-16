#!/usr/bin/env bash

# 阿里云 SMTP + Cloudflare 临时邮箱自动回复安装器

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

INSTALL_DIR="/root/cf_auto_reply"
PYTHON_SCRIPT="auto_reply_daemon.py"
CONFIG_FILE="${INSTALL_DIR}/config.json"
SERVICE_NAME="cf_reply"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

require_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        echo -e "${RED}错误：必须使用 root 用户运行此脚本。${PLAIN}"
        exit 1
    fi
}

pause_menu() {
    local ignored
    printf '按回车键返回...'
    IFS= read -r ignored || true
}

service_is_installed() {
    [[ -f "$SERVICE_FILE" ]]
}

show_recent_logs() {
    journalctl -u "$SERVICE_NAME" -n 30 --no-pager 2>/dev/null || true
}

restart_service() {
    if ! service_is_installed; then
        echo -e "${YELLOW}服务尚未安装，本次只保存配置。${PLAIN}"
        return 0
    fi

    if systemctl restart "$SERVICE_NAME" && systemctl is-active --quiet "$SERVICE_NAME"; then
        echo -e "${GREEN}配置已生效，服务已自动重启。${PLAIN}"
        return 0
    fi

    echo -e "${RED}服务重启失败，最近日志如下：${PLAIN}"
    show_recent_logs
    return 1
}

# 旧版本把凭据直接写在 Python 文件中。首次升级时先迁移，避免覆盖原配置。
migrate_legacy_config() {
    local script_path="${INSTALL_DIR}/${PYTHON_SCRIPT}"

    [[ ! -f "$CONFIG_FILE" && -f "$script_path" ]] || return 0

    python3 - "$script_path" "$CONFIG_FILE" <<'PY'
import ast
import json
import os
import sys
import tempfile
from pathlib import Path

source_path = Path(sys.argv[1])
config_path = Path(sys.argv[2])
name_map = {
    "CF_API_URL": "cf_api_url",
    "CF_API_TOKEN": "cf_api_token",
    "SMTP_USER": "smtp_user",
    "SMTP_PASS": "smtp_pass",
}
placeholders = {
    "URL_PLACEHOLDER",
    "TOKEN_PLACEHOLDER",
    "USER_PLACEHOLDER",
    "PASS_PLACEHOLDER",
}
config = {value: "" for value in name_map.values()}

try:
    tree = ast.parse(source_path.read_text(encoding="utf-8"))
except (OSError, SyntaxError) as exc:
    print(f"读取旧配置失败：{exc}", file=sys.stderr)
    raise SystemExit(1)

for node in tree.body:
    if not isinstance(node, ast.Assign) or len(node.targets) != 1:
        continue
    target = node.targets[0]
    if not isinstance(target, ast.Name) or target.id not in name_map:
        continue
    if isinstance(node.value, ast.Constant) and isinstance(node.value.value, str):
        value = node.value.value
        config[name_map[target.id]] = "" if value in placeholders else value

config_path.parent.mkdir(parents=True, exist_ok=True)
fd, temp_path = tempfile.mkstemp(prefix=".config.", dir=config_path.parent)
try:
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(config, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    os.replace(temp_path, config_path)
finally:
    if os.path.exists(temp_path):
        os.unlink(temp_path)
PY
}

prepare_config() {
    install -d -m 700 "$INSTALL_DIR"
    migrate_legacy_config || return 1

    if [[ ! -f "$CONFIG_FILE" ]]; then
        python3 - "$CONFIG_FILE" <<'PY'
import json
import os
import sys
from pathlib import Path

path = Path(sys.argv[1])
config = {
    "cf_api_url": "",
    "cf_api_token": "",
    "smtp_user": "",
    "smtp_pass": "",
}
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, "w", encoding="utf-8") as handle:
    json.dump(config, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
PY
    fi

    chmod 600 "$CONFIG_FILE"
}

write_config_value() {
    local key="$1" value="$2"

    python3 - "$CONFIG_FILE" "$key" 3< <(printf '%s' "$value") <<'PY'
import json
import os
import sys
import tempfile
from pathlib import Path

path = Path(sys.argv[1])
key = sys.argv[2]
with path.open("r", encoding="utf-8") as handle:
    config = json.load(handle)

with os.fdopen(3, "r", encoding="utf-8") as value_stream:
    config[key] = value_stream.read()

fd, temp_path = tempfile.mkstemp(prefix=".config.", dir=path.parent)
try:
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(config, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    os.replace(temp_path, path)
finally:
    if os.path.exists(temp_path):
        os.unlink(temp_path)
PY
}

validate_config() {
    python3 - "$CONFIG_FILE" <<'PY'
import json
import sys
from pathlib import Path
from urllib.parse import urlparse

path = Path(sys.argv[1])
required = {
    "cf_api_url": "CF API URL",
    "cf_api_token": "CF JWT Token",
    "smtp_user": "阿里云发信账号",
    "smtp_pass": "阿里云 SMTP 密码",
}

try:
    with path.open("r", encoding="utf-8") as handle:
        config = json.load(handle)
except (OSError, json.JSONDecodeError) as exc:
    print(f"配置文件无效：{exc}", file=sys.stderr)
    raise SystemExit(1)

missing = [label for key, label in required.items() if not str(config.get(key, "")).strip()]
if missing:
    print("以下配置不能为空：" + "、".join(missing), file=sys.stderr)
    raise SystemExit(1)

url = urlparse(str(config["cf_api_url"]).strip())
if url.scheme not in {"http", "https"} or not url.netloc:
    print("CF API URL 必须是完整的 http:// 或 https:// 地址。", file=sys.stderr)
    raise SystemExit(1)

if "@" not in str(config["smtp_user"]):
    print("阿里云发信账号格式不正确。", file=sys.stderr)
    raise SystemExit(1)
PY
}

generate_python_payload() {
    local target="${INSTALL_DIR}/${PYTHON_SCRIPT}"
    local temp="${target}.tmp"

    install -d -m 700 "$INSTALL_DIR"
    cat > "$temp" <<'PY'
#!/usr/bin/env python3

import json
import os
import smtplib
import time
from email.message import EmailMessage
from pathlib import Path

import requests

CONFIG_FILE = Path("/root/cf_auto_reply/config.json")
RECORD_FILE = Path("/root/cf_auto_reply/replied_ids.txt")
SMTP_SERVER = "smtpdm-ap-southeast-1.aliyun.com"
SMTP_PORT = 465
POLL_INTERVAL = 60
REPLY_BODY = """您好：

您的邮件我们已经收到。我们将尽快评估并与您取得联系。

（这是一封系统自动回复邮件，请勿直接回复）"""


def load_config():
    with CONFIG_FILE.open("r", encoding="utf-8") as handle:
        config = json.load(handle)

    required = ("cf_api_url", "cf_api_token", "smtp_user", "smtp_pass")
    missing = [key for key in required if not str(config.get(key, "")).strip()]
    if missing:
        raise RuntimeError("配置不完整：" + ", ".join(missing))
    return config


def get_replied_ids():
    try:
        with RECORD_FILE.open("r", encoding="utf-8") as handle:
            return {line.strip() for line in handle if line.strip()}
    except FileNotFoundError:
        return set()


def save_replied_id(message_id):
    with RECORD_FILE.open("a", encoding="utf-8") as handle:
        handle.write(f"{message_id}\n")
        handle.flush()
        os.fsync(handle.fileno())


def get_new_emails(config, replied_ids):
    headers = {"Authorization": f"Bearer {config['cf_api_token']}"}
    response = requests.get(config["cf_api_url"], headers=headers, timeout=15)
    response.raise_for_status()
    payload = response.json()
    emails = payload.get("data", [])
    if not isinstance(emails, list):
        raise ValueError("API 返回的 data 不是邮件列表")

    new_emails = []
    seen_ids = set()
    for email in emails:
        if not isinstance(email, dict) or email.get("id") is None:
            continue
        message_id = str(email["id"])
        if message_id in replied_ids or message_id in seen_ids:
            continue
        seen_ids.add(message_id)
        new_emails.append(email)
    return new_emails


def run_auto_responder(config):
    replied_ids = get_replied_ids()
    try:
        new_emails = get_new_emails(config, replied_ids)
    except (requests.RequestException, ValueError, json.JSONDecodeError) as exc:
        print(f"获取 API 失败：{exc}", flush=True)
        return

    if not new_emails:
        return
    print(f"发现 {len(new_emails)} 封新邮件，准备回复...", flush=True)

    try:
        with smtplib.SMTP_SSL(SMTP_SERVER, SMTP_PORT, timeout=20) as smtp:
            smtp.login(config["smtp_user"], config["smtp_pass"])
            for email_data in new_emails:
                message_id = str(email_data["id"])
                sender_addr = str(email_data.get("source") or "").strip()
                if not sender_addr or sender_addr.casefold() == config["smtp_user"].casefold():
                    continue

                reply = EmailMessage()
                reply.set_content(REPLY_BODY)
                reply["Subject"] = "Re: 您的邮件已收到"
                reply["From"] = f"系统自动回复 <{config['smtp_user']}>"
                reply["To"] = sender_addr

                try:
                    smtp.send_message(reply)
                    save_replied_id(message_id)
                    print(f"已回复：{sender_addr}", flush=True)
                except Exception as exc:
                    print(f"回复 {sender_addr} 失败：{exc}", flush=True)
    except (OSError, smtplib.SMTPException) as exc:
        print(f"SMTP 连接或登录失败：{exc}", flush=True)


def main():
    config = load_config()
    print("后台服务已启动，正在持续监听...", flush=True)
    while True:
        try:
            run_auto_responder(config)
        except Exception as exc:
            print(f"运行异常：{exc}", flush=True)
        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    main()
PY

    chmod 700 "$temp"
    mv -f "$temp" "$target"
}

interactive_config() {
    local restart_after="${1:-1}"
    local input_url input_token input_user input_pass backup changed=0

    clear 2>/dev/null || true
    echo -e "================================================="
    echo -e " ${CYAN}交互式配置向导${PLAIN}"
    echo -e "================================================="
    echo -e "${YELLOW}直接按回车键保留当前值。${PLAIN}"

    backup="$(mktemp "${INSTALL_DIR}/.config.backup.XXXXXX")" || return 1
    cp -p "$CONFIG_FILE" "$backup"

    IFS= read -r -p "1. 输入 CF API URL（例如 https://mail.example.com/api/messages）: " input_url
    if [[ -n "$input_url" ]]; then
        write_config_value "cf_api_url" "$input_url" || { mv -f "$backup" "$CONFIG_FILE"; return 1; }
        changed=1
    fi

    IFS= read -r -p "2. 输入 CF JWT Token（链接中 jwt= 后面的内容）: " input_token
    if [[ -n "$input_token" ]]; then
        write_config_value "cf_api_token" "$input_token" || { mv -f "$backup" "$CONFIG_FILE"; return 1; }
        changed=1
    fi

    IFS= read -r -p "3. 输入阿里云发信账号（如 sales@example.com）: " input_user
    if [[ -n "$input_user" ]]; then
        write_config_value "smtp_user" "$input_user" || { mv -f "$backup" "$CONFIG_FILE"; return 1; }
        changed=1
    fi

    IFS= read -r -p "4. 输入阿里云 SMTP 密码（输入内容会显示）: " input_pass
    if [[ -n "$input_pass" ]]; then
        write_config_value "smtp_pass" "$input_pass" || { mv -f "$backup" "$CONFIG_FILE"; return 1; }
        changed=1
    fi

    if ! validate_config; then
        mv -f "$backup" "$CONFIG_FILE"
        echo -e "${RED}配置未保存，已恢复修改前的内容。${PLAIN}"
        return 1
    fi

    rm -f "$backup"
    if ((changed == 1)); then
        echo -e "${GREEN}配置已保存。${PLAIN}"
    else
        echo -e "${YELLOW}没有输入新内容，配置保持不变。${PLAIN}"
    fi

    if [[ "$restart_after" == "1" ]]; then
        restart_service
    fi
}

write_service_file() {
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Cloudflare Temp Email Auto Reply
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=/usr/bin/python3 ${INSTALL_DIR}/${PYTHON_SCRIPT}
Restart=on-failure
RestartSec=10
Environment=PYTHONUNBUFFERED=1
UMask=0077
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
}

install_and_setup() {
    echo -e "${GREEN}>>> 安装运行环境（Python 3、Requests）...${PLAIN}"
    if ! apt-get update || ! DEBIAN_FRONTEND=noninteractive apt-get install -y python3 python3-requests; then
        echo -e "${RED}依赖安装失败，请检查 apt 源和网络。${PLAIN}"
        pause_menu
        return 1
    fi

    prepare_config || {
        echo -e "${RED}配置初始化或旧配置迁移失败。${PLAIN}"
        pause_menu
        return 1
    }
    generate_python_payload || {
        echo -e "${RED}生成后台程序失败。${PLAIN}"
        pause_menu
        return 1
    }
    interactive_config 0 || {
        pause_menu
        return 1
    }

    echo -e "${GREEN}>>> 注册并启动 systemd 服务...${PLAIN}"
    write_service_file || {
        echo -e "${RED}写入 systemd 服务失败。${PLAIN}"
        pause_menu
        return 1
    }
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"

    if systemctl restart "$SERVICE_NAME" && systemctl is-active --quiet "$SERVICE_NAME"; then
        echo -e "${GREEN}安装/更新完成，服务已在后台运行。${PLAIN}"
    else
        echo -e "${RED}服务启动失败，最近日志如下：${PLAIN}"
        show_recent_logs
    fi
    pause_menu
}

configure_service() {
    if ! command -v python3 >/dev/null 2>&1; then
        echo -e "${RED}未找到 Python 3，请先选择“一键安装”。${PLAIN}"
        return 1
    fi

    prepare_config || return 1
    generate_python_payload || return 1
    interactive_config 1
}

uninstall_service() {
    local confirm
    echo -e "${RED}即将彻底卸载服务。${PLAIN}"
    IFS= read -r -p "确认卸载？[y/N]: " confirm
    if [[ "$confirm" =~ ^[yY]$ ]]; then
        systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
        rm -f "$SERVICE_FILE"
        systemctl daemon-reload
        systemctl reset-failed "$SERVICE_NAME" >/dev/null 2>&1 || true
        rm -rf "$INSTALL_DIR"
        echo -e "${GREEN}卸载清理完毕。${PLAIN}"
    fi
    pause_menu
}

show_menu() {
    local choice
    while true; do
        clear 2>/dev/null || true
        echo -e "================================================="
        echo -e " ${CYAN}邮件自动回复 控制台${PLAIN}"
        echo -e "================================================="
        if systemctl is-active --quiet "$SERVICE_NAME"; then
            echo -e " 状态：${GREEN}运行中（Active）${PLAIN}"
        else
            echo -e " 状态：${RED}已停止 / 未安装（Inactive）${PLAIN}"
        fi
        echo -e "================================================="
        echo -e "  ${YELLOW}1.${PLAIN} 一键安装、配置并启动"
        echo -e "  ${YELLOW}2.${PLAIN} 修改配置并自动重启"
        echo -e "  ${YELLOW}3.${PLAIN} 重启服务"
        echo -e "  ${YELLOW}4.${PLAIN} 停止服务"
        echo -e "  ${YELLOW}5.${PLAIN} 启动服务"
        echo -e "  ${YELLOW}6.${PLAIN} 查看实时日志"
        echo -e "  ${YELLOW}9.${PLAIN} 彻底卸载与清理"
        echo -e "  ${YELLOW}0.${PLAIN} 退出脚本"
        echo -e "================================================="
        IFS= read -r -p "请输入选项 [0-9]: " choice || exit 0
        case "$choice" in
            1)
                install_and_setup
                ;;
            2)
                configure_service || true
                pause_menu
                ;;
            3)
                restart_service || true
                pause_menu
                ;;
            4)
                if systemctl stop "$SERVICE_NAME"; then
                    echo -e "${YELLOW}服务已停止。${PLAIN}"
                else
                    echo -e "${RED}停止失败，请确认服务已经安装。${PLAIN}"
                fi
                pause_menu
                ;;
            5)
                if systemctl start "$SERVICE_NAME"; then
                    echo -e "${GREEN}服务已启动。${PLAIN}"
                else
                    echo -e "${RED}启动失败，请确认服务已经安装。${PLAIN}"
                fi
                pause_menu
                ;;
            6)
                journalctl -u "$SERVICE_NAME" -f
                ;;
            9)
                uninstall_service
                ;;
            0)
                exit 0
                ;;
            *)
                echo -e "${RED}输入错误。${PLAIN}"
                sleep 1
                ;;
        esac
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    require_root
    show_menu
fi
