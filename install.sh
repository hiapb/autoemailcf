#!/bin/bash

# ==========================================
# 阿里云 + CF 临时邮自动回复 终极管理脚本
# ==========================================

# 字体颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

# ================= 核心配置 =================
GITHUB_REPO="https://github.com/你的用户名/你的仓库.git" # 请替换为真实地址
INSTALL_DIR="/root/cf_auto_reply"
PYTHON_SCRIPT="auto_reply_daemon.py" # 你的 Python 脚本文件名
SERVICE_NAME="cf_reply"
# ==========================================

# 确保使用 root 权限运行
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误: 必须使用 root 用户运行此脚本！${PLAIN}"
   exit 1
fi

install_env() {
    echo -e "${GREEN}>>> 开始更新系统并安装环境...${PLAIN}"
    apt update -y
    apt install -y git python3 python3-pip
    apt install -y python3-requests || pip3 install requests
    
    if [ -d "$INSTALL_DIR" ]; then
        echo -e "${YELLOW}目录已存在，正在拉取最新代码...${PLAIN}"
        cd $INSTALL_DIR && git pull
    else
        echo -e "${GREEN}>>> 正在从 GitHub 克隆代码...${PLAIN}"
        git clone $GITHUB_REPO $INSTALL_DIR
    fi
    echo -e "${GREEN}环境与代码部署完毕！请选择 [8] 进行交互式配置。${PLAIN}"
    read -n 1 -s -r -p "按任意键返回菜单..."
}

config_service() {
    echo -e "${GREEN}>>> 正在配置 systemd 守护进程...${PLAIN}"
    cat > /etc/systemd/system/${SERVICE_NAME}.service << EOF
[Unit]
Description=Cloudflare Temp Email Auto Reply Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=/usr/bin/python3 ${INSTALL_DIR}/${PYTHON_SCRIPT}
Restart=always
RestartSec=10
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=${SERVICE_NAME}

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable ${SERVICE_NAME}
    echo -e "${GREEN}Systemd 服务配置成功！并已设置开机自启。${PLAIN}"
    read -n 1 -s -r -p "按任意键返回菜单..."
}

interactive_config() {
    clear
    echo -e "================================================="
    echo -e " ${CYAN}⚙️  交互式配置向导${PLAIN}"
    echo -e "================================================="
    
    if [ ! -f "$INSTALL_DIR/$PYTHON_SCRIPT" ]; then
        echo -e "${RED}错误：找不到文件 $INSTALL_DIR/$PYTHON_SCRIPT！请先执行 [1] 拉取代码。${PLAIN}"
        read -n 1 -s -r -p "按任意键返回菜单..."
        return
    fi

    echo -e "${YELLOW}提示：如果某一项不需要修改，请直接按回车键跳过。${PLAIN}"
    echo -e "-------------------------------------------------"

    # 1. 交互输入 CF URL
    read -p "1. 请输入 CF API URL (例如 https://.../messages): " input_cf_url
    if [[ -n "$input_cf_url" ]]; then
        sed -i "s#^CF_API_URL.*#CF_API_URL = \"${input_cf_url}\"#" "$INSTALL_DIR/$PYTHON_SCRIPT"
        echo -e "${GREEN} -> CF API URL 已更新${PLAIN}"
    fi

    # 2. 交互输入 CF Token
    read -p "2. 请输入 CF API Token: " input_cf_token
    if [[ -n "$input_cf_token" ]]; then
        sed -i "s#^CF_API_TOKEN.*#CF_API_TOKEN = \"${input_cf_token}\"#" "$INSTALL_DIR/$PYTHON_SCRIPT"
        echo -e "${GREEN} -> CF API Token 已更新${PLAIN}"
    fi

    # 3. 交互输入 SMTP 账号
    read -p "3. 请输入阿里云发件账号 (如 sales@email.clodom.link): " input_smtp_user
    if [[ -n "$input_smtp_user" ]]; then
        sed -i "s#^SMTP_USER.*#SMTP_USER = \"${input_smtp_user}\"#" "$INSTALL_DIR/$PYTHON_SCRIPT"
        echo -e "${GREEN} -> SMTP 发件账号 已更新${PLAIN}"
    fi

    # 4. 交互输入 SMTP 密码
    read -p "4. 请输入阿里云 SMTP 密码: " input_smtp_pass
    if [[ -n "$input_smtp_pass" ]]; then
        sed -i "s#^SMTP_PASS.*#SMTP_PASS = \"${input_smtp_pass}\"#" "$INSTALL_DIR/$PYTHON_SCRIPT"
        echo -e "${GREEN} -> SMTP 密码 已更新${PLAIN}"
    fi

    echo -e "================================================="
    echo -e "${GREEN}🎉 配置修改完毕并已保存到文件中！${PLAIN}"
    echo -e "${YELLOW}⚠️ 注意：如果服务当前正在运行，请返回主菜单选择【5】重启服务，新配置才会生效。${PLAIN}"
    
    read -n 1 -s -r -p "按任意键返回菜单..."
}

uninstall_service() {
    echo -e "${RED}>>> 警告：即将执行卸载操作！${PLAIN}"
    read -p "确定要停止并删除系统服务吗？[y/N]: " confirm_service
    if [[ "$confirm_service" =~ ^[yY]$ ]]; then
        systemctl stop ${SERVICE_NAME} &>/dev/null
        systemctl disable ${SERVICE_NAME} &>/dev/null
        rm -f /etc/systemd/system/${SERVICE_NAME}.service
        systemctl daemon-reload
        echo -e "${GREEN}守护服务已成功卸载。${PLAIN}"
    fi

    read -p "是否需要彻底删除源代码目录 ($INSTALL_DIR)？[y/N]: " confirm_dir
    if [[ "$confirm_dir" =~ ^[yY]$ ]]; then
        rm -rf $INSTALL_DIR
        echo -e "${GREEN}代码目录已清理完毕。${PLAIN}"
    fi
    echo -e "${GREEN}卸载流程结束。${PLAIN}"
    read -n 1 -s -r -p "按任意键返回菜单..."
}

view_logs() {
    echo -e "${GREEN}>>> 正在查看实时日志 (按 Ctrl+C 退出日志查看)...${PLAIN}"
    journalctl -u ${SERVICE_NAME} -f
}

show_menu() {
    while true; do
        clear
        echo -e "================================================="
        echo -e " ${CYAN}🚀 自动回复机器人 终极版一键管理脚本${PLAIN}"
        echo -e "================================================="
        
        # 状态检查模块
        if systemctl is-active --quiet ${SERVICE_NAME}; then
            STATUS="${GREEN}运行中 (Active)${PLAIN}"
        else
            STATUS="${RED}已停止 / 未安装 (Inactive)${PLAIN}"
        fi
        echo -e " 当前服务状态: $STATUS"
        echo -e "================================================="
        
        echo -e "  ${YELLOW}1.${PLAIN} 📦 一键安装环境与拉取代码"
        echo -e "  ${YELLOW}2.${PLAIN} ⚙️  配置并注册后台服务"
        echo -e "  ${YELLOW}3.${PLAIN} ▶️  启动服务"
        echo -e "  ${YELLOW}4.${PLAIN} ⏹️  停止服务"
        echo -e "  ${YELLOW}5.${PLAIN} 🔄 重启服务"
        echo -e "  ${YELLOW}6.${PLAIN} 📝 查看实时运行日志"
        echo -e "-------------------------------------------------"
        echo -e "  ${YELLOW}7.${PLAIN} ⬇️  更新最新代码"
        echo -e "  ${YELLOW}8.${PLAIN} ✏️  修改配置"
        echo -e "  ${YELLOW}9.${PLAIN} 🗑️  彻底卸载服务与清理文件"
        echo -e "-------------------------------------------------"
        echo -e "  ${YELLOW}0.${PLAIN} ❌ 退出脚本"
        echo -e "================================================="
        
        read -p "请输入选项 [0-9]: " choice
        case "$choice" in
            1) install_env ;;
            2) config_service ;;
            3) systemctl start ${SERVICE_NAME}
               echo -e "${GREEN}服务已启动！${PLAIN}"
               read -n 1 -s -r -p "按任意键返回菜单..." ;;
            4) systemctl stop ${SERVICE_NAME}
               echo -e "${YELLOW}服务已停止！${PLAIN}"
               read -n 1 -s -r -p "按任意键返回菜单..." ;;
            5) systemctl restart ${SERVICE_NAME}
               echo -e "${GREEN}服务已重启！${PLAIN}"
               read -n 1 -s -r -p "按任意键返回菜单..." ;;
            6) view_logs ;;
            7) echo -e "${GREEN}正在拉取最新代码...${PLAIN}"
               cd $INSTALL_DIR && git pull
               systemctl restart ${SERVICE_NAME}
               echo -e "${GREEN}更新完毕并已重启服务！${PLAIN}"
               read -n 1 -s -r -p "按任意键返回菜单..." ;;
            8) interactive_config ;;
            9) uninstall_service ;;
            0) echo -e "${GREEN}已退出管理面板。${PLAIN}"; exit 0 ;;
            *) echo -e "${RED}请输入正确的数字选项！${PLAIN}"; sleep 1 ;;
        esac
    done
}

show_menu
