#!/usr/bin/env bash
# Remove -u flag to avoid unbound variable errors
set -o pipefail

# ═══════════════════════════════════════════════════════════════════════════════
#  CHROMIUM RDP CONTROL PANEL v2.0
#  Interactive manager for Chromium RDP containers with Cloudflare tunnels
# ═══════════════════════════════════════════════════════════════════════════════

### CONFIG ###
IMAGE="ghcr.io/linuxserver/chromium:latest"
CONFIG_DIR="$HOME/.chromium-rdp"
SESSIONS_DIR="$CONFIG_DIR/sessions"
BIN_DIR="$HOME/bin"
CLOUDFLARED="$BIN_DIR/cloudflared"
VERSION="2.0.0"

# Initialize session variables with defaults
SESSION_NAME=""
SESSION_PORT=""
SESSION_MEMORY="2048"
SESSION_SHM="1g"
CUSTOM_USERNAME=""
CUSTOM_PASSWORD=""
TUNNEL_ENABLED="true"
TUNNEL_URL=""
TASKBAR_STYLE="modern"
CREATED_AT=""

# Create directories
mkdir -p "$BIN_DIR" "$CONFIG_DIR" "$SESSIONS_DIR"
export PATH="$BIN_DIR:$PATH"

### COLORS ###
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
GRAY='\033[0;90m'
NC='\033[0m'
BOLD='\033[1m'

### LOGGING ###
log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
log_error()   { echo -e "${RED}[✗]${NC} $1"; }
log_input()   { echo -en "${CYAN}[INPUT]${NC} $1"; }

### DISPLAY HEADER ###
display_header() {
    clear
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}  ${PURPLE}█▀▀ █░█ █▀█ █▀█ █▀▄▀█ █ █░█ █▀▄▀█   █▀█ █▀▄ █▀█${NC}                              ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  ${PURPLE}█▄▄ █▀█ █▀▄ █▄█ █░▀░█ █ █▄█ █░▀░█   █▀▄ █▄▀ █▀▀${NC}                              ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}                                                                              ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}                    ${GRAY}━━━ CONTROL PANEL v${VERSION} ━━━${NC}                               ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo
}

### UTILITIES ###
command_exists() { command -v "$1" >/dev/null 2>&1; }
random_port() { shuf -i 20000-45000 -n 1; }
port_free() { ! ss -tuln 2>/dev/null | grep -q ":$1 "; }

get_free_port() {
    local attempts=0
    while [ $attempts -lt 50 ]; do
        local port
        port=$(random_port)
        if port_free "$port"; then
            echo "$port"
            return 0
        fi
        ((attempts++))
    done
    return 1
}

validate_input() {
    local input_type="$1"
    local input_value="$2"
    
    case "$input_type" in
        "name")
            if [[ -z "$input_value" ]] || ! [[ "$input_value" =~ ^[a-zA-Z0-9_-]+$ ]]; then
                log_error "Name can only contain letters, numbers, hyphens, and underscores"
                return 1
            fi
            ;;
        "port")
            if ! [[ "$input_value" =~ ^[0-9]+$ ]] || [ "$input_value" -lt 1024 ] || [ "$input_value" -gt 65535 ]; then
                log_error "Must be a valid port number (1024-65535)"
                return 1
            fi
            ;;
        "number")
            if ! [[ "$input_value" =~ ^[0-9]+$ ]]; then
                log_error "Must be a number"
                return 1
            fi
            ;;
    esac
    return 0
}

### CHECK IF SESSION IS RUNNING ###
is_session_running() {
    local session_name="$1"
    docker ps --format "{{.Names}}" 2>/dev/null | grep -q "^${session_name}$"
}

### GET TUNNEL URL ###
get_tunnel_url() {
    local session_name="$1"
    local log_file="$CONFIG_DIR/${session_name}.tunnel.log"
    if [[ -f "$log_file" ]]; then
        grep -o 'https://[-a-z0-9]*\.trycloudflare.com' "$log_file" 2>/dev/null | head -n 1
    fi
}

### SESSION MANAGEMENT ###
get_session_list() {
    find "$SESSIONS_DIR" -name "*.conf" -exec basename {} .conf \; 2>/dev/null | sort
}

load_session() {
    local session_name="$1"
    local config_file="$SESSIONS_DIR/${session_name}.conf"
    
    if [[ -f "$config_file" ]]; then
        # Reset variables to defaults before loading
        SESSION_NAME=""
        SESSION_PORT=""
        SESSION_MEMORY="2048"
        SESSION_SHM="1g"
        CUSTOM_USERNAME=""
        CUSTOM_PASSWORD=""
        TUNNEL_ENABLED="true"
        TUNNEL_URL=""
        TASKBAR_STYLE="modern"
        CREATED_AT=""
        
        # Source the config file
        source "$config_file"
        return 0
    fi
    return 1
}

save_session() {
    local config_file="$SESSIONS_DIR/${SESSION_NAME}.conf"
    
    # Ensure defaults for empty values
    SESSION_MEMORY="${SESSION_MEMORY:-2048}"
    SESSION_SHM="${SESSION_SHM:-1g}"
    TUNNEL_ENABLED="${TUNNEL_ENABLED:-true}"
    TASKBAR_STYLE="${TASKBAR_STYLE:-modern}"
    CREATED_AT="${CREATED_AT:-$(date)}"
    
    cat > "$config_file" <<EOF
# Session configuration for ${SESSION_NAME}
SESSION_NAME="${SESSION_NAME}"
SESSION_PORT="${SESSION_PORT}"
SESSION_MEMORY="${SESSION_MEMORY}"
SESSION_SHM="${SESSION_SHM}"
CUSTOM_USERNAME="${CUSTOM_USERNAME}"
CUSTOM_PASSWORD="${CUSTOM_PASSWORD}"
TUNNEL_ENABLED="${TUNNEL_ENABLED}"
TUNNEL_URL="${TUNNEL_URL}"
TASKBAR_STYLE="${TASKBAR_STYLE}"
CREATED_AT="${CREATED_AT}"
EOF
}

### INSTALL CLOUDFLARED ###
install_cloudflared() {
    log_info "Installing cloudflared..."
    
    local arch
    arch=$(uname -m)
    local cf_arch="amd64"
    [[ "$arch" == "aarch64" ]] && cf_arch="arm64"
    
    if curl -sL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${cf_arch}" -o "$CLOUDFLARED" 2>/dev/null; then
        chmod +x "$CLOUDFLARED"
        log_success "cloudflared installed successfully"
    else
        log_error "Failed to download cloudflared"
        return 1
    fi
}

### SETUP ENHANCED TASKBAR ###
setup_taskbar() {
    local container=$1
    local style=${2:-modern}
    
    log_info "Installing enhanced taskbar (style: $style)..."
    
    # Install tint2 and additional tools
    docker exec "$container" bash -c '
        apt-get update -qq
        apt-get install -y -qq tint2 fonts-noto-color-emoji fonts-font-awesome >/dev/null 2>&1
        mkdir -p /config/.config/tint2 /config/.config/openbox
    ' 2>/dev/null

    # Enhanced tint2 configuration based on style
    case $style in
        modern)
            docker exec "$container" bash -c 'cat > /config/.config/tint2/tint2rc << "TINT2EOF"
# Panel
panel_items = LTSC
panel_size = 100% 42
panel_margin = 0 0
panel_padding = 8 4 8
panel_background_id = 1
panel_position = bottom center horizontal
panel_layer = top
panel_monitor = all
panel_shrink = 0

# Backgrounds
rounded = 0
border_width = 0
border_sides = T
background_color = #1a1a2e 95
border_color = #6366f1 60

rounded = 8
border_width = 0
background_color = #6366f1 80
background_color_hover = #818cf8 90
background_color_pressed = #4f46e5 100

rounded = 6
border_width = 0
background_color = #22223b 80
background_color_hover = #33334d 90

# Taskbar
taskbar_mode = single_desktop
taskbar_hide_if_empty = 0
taskbar_padding = 4 4 4
taskbar_background_id = 0
taskbar_active_background_id = 0

# Tasks
task_text = 1
task_icon = 1
task_centered = 0
task_tooltip = 1
task_maximum_size = 180 35
task_padding = 8 4 8
task_font = Sans 10
task_font_color = #ffffff 90
task_icon_size = 20
task_background_id = 3
task_active_background_id = 2

# Launcher
launcher_padding = 4 4 4
launcher_background_id = 0
launcher_icon_size = 24
launcher_icon_theme = Adwaita

# System Tray
systray_padding = 4 4 4
systray_background_id = 0
systray_icon_size = 22
systray_icon_asb = 100 0 0

# Clock
time1_format = %H:%M
time1_font = Sans Bold 11
time2_format = %a %d %b
time2_font = Sans 9
clock_font_color = #ffffff 90
clock_padding = 12 4
clock_background_id = 3
clock_tooltip = %A %d %B %Y
TINT2EOF'
            ;;
        minimal)
            docker exec "$container" bash -c 'cat > /config/.config/tint2/tint2rc << "TINT2EOF"
panel_items = TSC
panel_size = 50% 36
panel_position = bottom center horizontal
panel_padding = 8 4 8
panel_margin = 0 8
panel_background_id = 1

rounded = 18
border_width = 0
background_color = #000000 85

rounded = 14
border_width = 0
background_color = #ffffff 20
background_color_hover = #ffffff 30

task_text = 1
task_icon = 0
task_centered = 1
task_maximum_size = 140 28
task_padding = 8 4 8
task_font = Sans 9
task_font_color = #ffffff 85
task_background_id = 2
task_active_background_id = 2

time1_format = %H:%M
time1_font = Sans 10
clock_font_color = #ffffff 85
clock_padding = 8 4
clock_background_id = 0
TINT2EOF'
            ;;
        glassmorphism)
            docker exec "$container" bash -c 'cat > /config/.config/tint2/tint2rc << "TINT2EOF"
panel_items = LTSC
panel_size = 100% 48
panel_position = bottom center horizontal
panel_padding = 12 6 12
panel_margin = 0 0
panel_background_id = 1

rounded = 0
border_width = 1
border_sides = T
background_color = #0f0f23 75
border_color = #ffffff 15

rounded = 12
border_width = 1
background_color = #6366f1 70
border_color = #a5b4fc 40
background_color_hover = #818cf8 85

rounded = 10
border_width = 1
background_color = #ffffff 8
border_color = #ffffff 10
background_color_hover = #ffffff 15

task_text = 1
task_icon = 1
task_centered = 0
task_maximum_size = 200 38
task_padding = 10 6 10
task_font = Sans 10
task_font_color = #ffffff 95
task_icon_size = 22
task_background_id = 3
task_active_background_id = 2

launcher_padding = 6 6 6
launcher_icon_size = 26
launcher_background_id = 0

systray_padding = 6 6 8
systray_icon_size = 20

time1_format = %H:%M
time1_font = Sans Bold 12
time2_format = %A
time2_font = Sans 9
clock_font_color = #ffffff 90
clock_padding = 14 6
clock_background_id = 3
TINT2EOF'
            ;;
    esac

    # Openbox autostart
    docker exec "$container" bash -c 'cat > /config/.config/openbox/autostart << "AUTOEOF"
# Kill existing tint2 instances
pkill -9 tint2 2>/dev/null
sleep 1

# Start tint2 taskbar
tint2 &
AUTOEOF'

    log_success "Taskbar configured ($style style)"
}

### CREATE NEW SESSION ###
create_session() {
    display_header
    log_info "Creating new RDP session"
    echo
    
    # Initialize all variables
    SESSION_NAME=""
    SESSION_PORT=""
    SESSION_MEMORY="2048"
    SESSION_SHM="1g"
    CUSTOM_USERNAME=""
    CUSTOM_PASSWORD=""
    TUNNEL_ENABLED="true"
    TUNNEL_URL=""
    TASKBAR_STYLE="modern"
    CREATED_AT=""
    
    # Session name
    local input_name=""
    while true; do
        log_input "Session name (default: chromium-rdp): "
        read input_name
        input_name="${input_name:-chromium-rdp}"
        
        if ! validate_input "name" "$input_name"; then
            continue
        fi
        
        if [[ -f "$SESSIONS_DIR/${input_name}.conf" ]]; then
            log_error "Session '$input_name' already exists"
            continue
        fi
        SESSION_NAME="$input_name"
        break
    done
    
    # Port
    local default_port
    default_port=$(get_free_port)
    local input_port=""
    while true; do
        log_input "Port (default: $default_port): "
        read input_port
        input_port="${input_port:-$default_port}"
        
        if ! validate_input "port" "$input_port"; then
            continue
        fi
        
        if ! port_free "$input_port"; then
            log_error "Port $input_port is already in use"
            continue
        fi
        SESSION_PORT="$input_port"
        break
    done
    
    # Memory
    local input_memory=""
    log_input "Memory in MB (default: 2048): "
    read input_memory
    SESSION_MEMORY="${input_memory:-2048}"
    
    # Shared memory
    local input_shm=""
    log_input "Shared memory size (default: 1g): "
    read input_shm
    SESSION_SHM="${input_shm:-1g}"
    
    # Custom credentials (optional)
    echo
    log_info "Custom credentials (optional - for basic auth):"
    local input_username=""
    log_input "Username (leave empty to skip): "
    read input_username
    CUSTOM_USERNAME="$input_username"
    
    if [[ -n "$CUSTOM_USERNAME" ]]; then
        local input_password=""
        log_input "Password: "
        read -s input_password
        CUSTOM_PASSWORD="$input_password"
        echo
    fi
    
    # Cloudflare tunnel
    local tunnel_choice=""
    log_input "Enable Cloudflare tunnel? (Y/n): "
    read tunnel_choice
    TUNNEL_ENABLED="true"
    [[ "$tunnel_choice" =~ ^[Nn]$ ]] && TUNNEL_ENABLED="false"
    
    # Taskbar style
    echo
    log_info "Select taskbar style:"
    echo "  1) Modern (default - full featured)"
    echo "  2) Minimal (compact, centered)"
    echo "  3) Glassmorphism (transparent, elegant)"
    local taskbar_choice=""
    log_input "Choice (1-3): "
    read taskbar_choice
    
    case "$taskbar_choice" in
        2) TASKBAR_STYLE="minimal" ;;
        3) TASKBAR_STYLE="glassmorphism" ;;
        *) TASKBAR_STYLE="modern" ;;
    esac
    
    CREATED_AT="$(date)"
    TUNNEL_URL=""
    
    # Save configuration
    save_session
    
    echo
    log_success "Session configuration saved!"
    local start_choice=""
    log_input "Start session now? (Y/n): "
    read start_choice
    
    if [[ ! "$start_choice" =~ ^[Nn]$ ]]; then
        start_session "$SESSION_NAME"
    fi
}

### START SESSION ###
start_session() {
    local session_to_start="$1"
    
    if ! load_session "$session_to_start"; then
        log_error "Session '$session_to_start' not found"
        return 1
    fi
    
    if is_session_running "$session_to_start"; then
        log_warn "Session '$session_to_start' is already running"
        return 0
    fi
    
    log_info "Starting session: $session_to_start"
    
    # Stop any existing container with same name
    docker rm -f "$session_to_start" 2>/dev/null
    
    # Start container with docker run
    local run_result
    if [[ -n "$CUSTOM_USERNAME" ]] && [[ -n "$CUSTOM_PASSWORD" ]]; then
        run_result=$(docker run -d \
            --name "$session_to_start" \
            -p "${SESSION_PORT}:3000" \
            -v "${CONFIG_DIR}/data-${session_to_start}:/config" \
            --shm-size="${SESSION_SHM}" \
            --restart unless-stopped \
            -e "CUSTOM_USER=$CUSTOM_USERNAME" \
            -e "PASSWORD=$CUSTOM_PASSWORD" \
            "$IMAGE" 2>&1)
    else
        run_result=$(docker run -d \
            --name "$session_to_start" \
            -p "${SESSION_PORT}:3000" \
            -v "${CONFIG_DIR}/data-${session_to_start}:/config" \
            --shm-size="${SESSION_SHM}" \
            --restart unless-stopped \
            "$IMAGE" 2>&1)
    fi
    
    if [[ $? -ne 0 ]]; then
        log_error "Failed to start container: $run_result"
        return 1
    fi
    
    log_success "Container started"
    log_info "Waiting for initialization..."
    sleep 5
    
    # Setup taskbar
    setup_taskbar "$session_to_start" "$TASKBAR_STYLE"
    
    # Restart to apply taskbar
    log_info "Applying taskbar configuration..."
    docker restart "$session_to_start" >/dev/null 2>&1
    sleep 3
    
    # Start tunnel if enabled
    if [[ "$TUNNEL_ENABLED" == "true" ]]; then
        log_info "Starting Cloudflare tunnel..."
        
        local log_file="$CONFIG_DIR/${session_to_start}.tunnel.log"
        pkill -f "cloudflared.*${SESSION_PORT}" 2>/dev/null
        sleep 1
        
        "$CLOUDFLARED" tunnel \
            --url "http://localhost:${SESSION_PORT}" \
            --no-autoupdate \
            > "$log_file" 2>&1 &
        
        # Wait for tunnel URL
        local wait_count=0
        TUNNEL_URL=""
        while [ $wait_count -lt 15 ]; do
            TUNNEL_URL=$(get_tunnel_url "$session_to_start")
            if [[ -n "$TUNNEL_URL" ]]; then
                break
            fi
            sleep 1
            ((wait_count++))
        done
        
        if [[ -z "$TUNNEL_URL" ]]; then
            log_warn "Could not get tunnel URL (tunnel may still be starting)"
        fi
        
        # Update session config with tunnel URL
        save_session
    fi
    
    # Display credentials
    display_credentials "$session_to_start"
}

### DISPLAY CREDENTIALS ###
display_credentials() {
    local name=$1
    load_session "$name"
    
    clear
    echo
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║${NC}                        ${BOLD}🚀 RDP SESSION READY${NC}                                  ${GREEN}║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC}                                                                              ${GREEN}║${NC}"
    printf "${GREEN}║${NC}  ${CYAN}📦 Session${NC}      : %-55s ${GREEN}║${NC}\n" "$name"
    printf "${GREEN}║${NC}  ${CYAN}🔌 Local Port${NC}   : %-55s ${GREEN}║${NC}\n" "$SESSION_PORT"
    printf "${GREEN}║${NC}  ${CYAN}🪟 Taskbar${NC}      : %-55s ${GREEN}║${NC}\n" "${TASKBAR_STYLE:-modern}"
    
    if [[ -n "${CUSTOM_USERNAME:-}" ]]; then
        printf "${GREEN}║${NC}  ${CYAN}👤 Username${NC}     : %-55s ${GREEN}║${NC}\n" "$CUSTOM_USERNAME"
        printf "${GREEN}║${NC}  ${CYAN}🔑 Password${NC}     : %-55s ${GREEN}║${NC}\n" "$CUSTOM_PASSWORD"
    fi
    
    echo -e "${GREEN}║${NC}                                                                              ${GREEN}║${NC}"
    
    if [[ -n "${TUNNEL_URL:-}" ]]; then
        echo -e "${GREEN}║${NC}  ${YELLOW}🌐 Public URL:${NC}                                                            ${GREEN}║${NC}"
        echo -e "${GREEN}║${NC}  ${BOLD}${BLUE}$TUNNEL_URL${NC}"
    else
        printf "${GREEN}║${NC}  ${YELLOW}🌐 Local URL${NC}    : %-55s ${GREEN}║${NC}\n" "http://localhost:${SESSION_PORT}"
    fi
    
    echo -e "${GREEN}║${NC}                                                                              ${GREEN}║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo
}

### STOP SESSION ###
stop_session() {
    local session_to_stop="$1"
    
    if ! load_session "$session_to_stop"; then
        log_error "Session '$session_to_stop' not found"
        return 1
    fi
    
    log_info "Stopping session: $session_to_stop"
    
    # Stop container
    if docker stop "$session_to_stop" >/dev/null 2>&1; then
        docker rm "$session_to_stop" >/dev/null 2>&1
        log_success "Container stopped"
    else
        log_warn "Container was not running"
    fi
    
    # Stop tunnel
    if [[ -n "$SESSION_PORT" ]]; then
        pkill -f "cloudflared.*${SESSION_PORT}" 2>/dev/null
    fi
    log_success "Tunnel stopped"
    
    # Clear tunnel URL
    TUNNEL_URL=""
    save_session
}

### DELETE SESSION ###
delete_session() {
    local session_to_delete="$1"
    
    if ! load_session "$session_to_delete"; then
        log_error "Session '$session_to_delete' not found"
        return 1
    fi
    
    echo
    log_warn "This will permanently delete session '$session_to_delete' and all its data!"
    local confirm=""
    log_input "Are you sure? (y/N): "
    read confirm
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        # Stop if running
        stop_session "$session_to_delete" 2>/dev/null
        
        # Remove files
        rm -f "$SESSIONS_DIR/${session_to_delete}.conf"
        rm -f "$CONFIG_DIR/${session_to_delete}.tunnel.log"
        rm -rf "$CONFIG_DIR/data-${session_to_delete}"
        
        log_success "Session '$session_to_delete' deleted"
    else
        log_info "Deletion cancelled"
    fi
}

### SHOW SESSION INFO ###
show_session_info() {
    local session_to_show="$1"
    
    if ! load_session "$session_to_show"; then
        log_error "Session '$session_to_show' not found"
        return 1
    fi
    
    local status="${RED}Stopped${NC}"
    if is_session_running "$session_to_show"; then
        status="${GREEN}Running${NC}"
    fi
    
    # Get fresh tunnel URL if running
    if is_session_running "$session_to_show" && [[ "$TUNNEL_ENABLED" == "true" ]]; then
        TUNNEL_URL=$(get_tunnel_url "$session_to_show")
    fi
    
    echo
    echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  Session: $session_to_show${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    echo
    echo -e "  Status         : $status"
    echo -e "  Port           : ${SESSION_PORT}"
    echo -e "  Memory         : ${SESSION_MEMORY}MB"
    echo -e "  Shared Memory  : ${SESSION_SHM}"
    echo -e "  Taskbar Style  : ${TASKBAR_STYLE}"
    echo -e "  Tunnel Enabled : ${TUNNEL_ENABLED}"
    
    if [[ -n "$TUNNEL_URL" ]]; then
        echo -e "  Tunnel URL     : ${CYAN}${TUNNEL_URL}${NC}"
    fi
    
    if [[ -n "$CUSTOM_USERNAME" ]]; then
        echo -e "  Username       : ${CUSTOM_USERNAME}"
        echo -e "  Password       : ${CUSTOM_PASSWORD}"
    fi
    
    echo -e "  Created        : ${CREATED_AT}"
    echo
    echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    echo
}

### EDIT SESSION ###
edit_session() {
    local session_to_edit="$1"
    
    if ! load_session "$session_to_edit"; then
        log_error "Session '$session_to_edit' not found"
        return 1
    fi
    
    while true; do
        display_header
        echo -e "Editing session: ${BOLD}$session_to_edit${NC}"
        echo
        echo "  1) Taskbar style (current: ${TASKBAR_STYLE})"
        echo "  2) Memory (current: ${SESSION_MEMORY}MB)"
        echo "  3) Shared memory (current: ${SESSION_SHM})"
        echo "  4) Custom username (current: ${CUSTOM_USERNAME:-not set})"
        echo "  5) Custom password"
        echo "  6) Toggle tunnel (current: ${TUNNEL_ENABLED})"
        echo "  0) Back"
        echo
        
        local edit_choice=""
        log_input "Enter choice: "
        read edit_choice
        
        case "$edit_choice" in
            1)
                echo
                echo "  1) Modern"
                echo "  2) Minimal"
                echo "  3) Glassmorphism"
                local style_choice=""
                log_input "Select style: "
                read style_choice
                case "$style_choice" in
                    1) TASKBAR_STYLE="modern" ;;
                    2) TASKBAR_STYLE="minimal" ;;
                    3) TASKBAR_STYLE="glassmorphism" ;;
                esac
                ;;
            2)
                local new_memory=""
                log_input "New memory (MB): "
                read new_memory
                SESSION_MEMORY="${new_memory:-$SESSION_MEMORY}"
                ;;
            3)
                local new_shm=""
                log_input "New shared memory (e.g., 1g, 512m): "
                read new_shm
                SESSION_SHM="${new_shm:-$SESSION_SHM}"
                ;;
            4)
                local new_username=""
                log_input "New username: "
                read new_username
                CUSTOM_USERNAME="$new_username"
                ;;
            5)
                local new_password=""
                log_input "New password: "
                read -s new_password
                CUSTOM_PASSWORD="$new_password"
                echo
                ;;
            6)
                if [[ "$TUNNEL_ENABLED" == "true" ]]; then
                    TUNNEL_ENABLED="false"
                else
                    TUNNEL_ENABLED="true"
                fi
                ;;
            0)
                save_session
                return 0
                ;;
        esac
        
        save_session
        log_success "Configuration updated"
        sleep 1
    done
}

### VIEW LOGS ###
view_logs() {
    local session_for_logs="$1"
    local log_file="$CONFIG_DIR/${session_for_logs}.tunnel.log"
    
    if [[ -f "$log_file" ]]; then
        log_info "Showing tunnel logs for '$session_for_logs' (Ctrl+C to exit)"
        echo
        tail -f "$log_file"
    else
        log_warn "No log file found for '$session_for_logs'"
    fi
}

### SHOW STATS ###
show_stats() {
    local session_for_stats="$1"
    
    if ! is_session_running "$session_for_stats"; then
        log_warn "Session '$session_for_stats' is not running"
        return 1
    fi
    
    echo
    log_info "Resource usage for: $session_for_stats"
    echo
    docker stats "$session_for_stats" --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}"
    echo
}

### LIST SESSIONS ###
list_sessions() {
    local session_list
    session_list=$(get_session_list)
    
    if [[ -z "$session_list" ]]; then
        log_info "No sessions found"
        return 0
    fi
    
    # Convert to array
    local sessions=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && sessions+=("$line")
    done <<< "$session_list"
    
    local count=${#sessions[@]}
    
    if [ $count -eq 0 ]; then
        log_info "No sessions found"
        return 0
    fi
    
    echo
    log_info "Found ${GREEN}$count${NC} session(s):"
    echo
    
    printf "  ${BOLD}%-3s %-25s %-10s %-8s %s${NC}\n" "#" "NAME" "STATUS" "PORT" "URL"
    echo "  ─────────────────────────────────────────────────────────────────────────"
    
    for i in "${!sessions[@]}"; do
        local current_session="${sessions[$i]}"
        load_session "$current_session"
        
        local status="${YELLOW}Stopped${NC}"
        local url="${GRAY}No tunnel${NC}"
        
        if is_session_running "$current_session"; then
            status="${GREEN}Running${NC}"
            local tunnel_url
            tunnel_url=$(get_tunnel_url "$current_session")
            if [[ -n "$tunnel_url" ]]; then
                url="${CYAN}$tunnel_url${NC}"
            fi
        fi
        
        printf "  %-3s %-25s " "$((i+1))" "$current_session"
        echo -en "$status"
        printf "   %-8s " "$SESSION_PORT"
        echo -e "$url"
    done
    echo
}

### STOP ALL ###
stop_all_sessions() {
    log_warn "This will stop ALL running sessions!"
    local confirm=""
    log_input "Are you sure? (y/N): "
    read confirm
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        local session_list
        session_list=$(get_session_list)
        
        if [[ -n "$session_list" ]]; then
            while IFS= read -r session_name; do
                if [[ -n "$session_name" ]] && is_session_running "$session_name"; then
                    stop_session "$session_name"
                fi
            done <<< "$session_list"
        fi
        log_success "All sessions stopped"
    fi
}

### MAIN MENU ###
main_menu() {
    while true; do
        display_header
        
        # Get session list
        local session_list
        session_list=$(get_session_list)
        
        # Convert to array
        local sessions=()
        if [[ -n "$session_list" ]]; then
            while IFS= read -r line; do
                [[ -n "$line" ]] && sessions+=("$line")
            done <<< "$session_list"
        fi
        
        local count=${#sessions[@]}
        
        if [ $count -gt 0 ]; then
            list_sessions
        fi
        
        echo -e "${GRAY}─────────────────────────────────────────────────────────────────────────────${NC}"
        echo
        echo -e "  ${GREEN}1)${NC} Create new session          ${CYAN}5)${NC} Show session info"
        echo -e "  ${GREEN}2)${NC} Start a session             ${CYAN}6)${NC} Edit configuration"
        echo -e "  ${YELLOW}3)${NC} Stop a session              ${PURPLE}7)${NC} View tunnel logs"
        echo -e "  ${RED}4)${NC} Delete a session            ${BLUE}8)${NC} Show resource stats"
        echo
        echo -e "  ${RED}9)${NC} Stop all sessions           ${GRAY}0)${NC} Exit"
        echo
        
        local menu_choice=""
        log_input "Enter your choice: "
        read menu_choice
        
        case "$menu_choice" in
            1)
                create_session
                ;;
            2|3|4|5|6|7|8)
                if [ $count -eq 0 ]; then
                    log_warn "No sessions available"
                    sleep 1
                    continue
                fi
                
                echo
                local session_num=""
                log_input "Enter session number: "
                read session_num
                
                if [[ "$session_num" =~ ^[0-9]+$ ]] && [ "$session_num" -ge 1 ] && [ "$session_num" -le $count ]; then
                    local selected="${sessions[$((session_num-1))]}"
                    case "$menu_choice" in
                        2) start_session "$selected" ;;
                        3) stop_session "$selected" ;;
                        4) delete_session "$selected" ;;
                        5) show_session_info "$selected" ;;
                        6) edit_session "$selected" ;;
                        7) view_logs "$selected" ;;
                        8) show_stats "$selected" ;;
                    esac
                else
                    log_error "Invalid selection"
                fi
                ;;
            9)
                stop_all_sessions
                ;;
            0)
                echo
                log_info "Goodbye! 👋"
                exit 0
                ;;
            *)
                log_error "Invalid option"
                ;;
        esac
        
        echo
        log_input "Press Enter to continue..."
        read
    done
}

### DEPENDENCY CHECK ###
if ! command_exists docker; then
    log_error "Docker not found. Please install Docker first."
    exit 1
fi

[ ! -x "$CLOUDFLARED" ] && install_cloudflared

### COMMAND LINE INTERFACE ###
CMD="${1:-}"
ARG="${2:-}"

case "$CMD" in
    create)
        create_session
        ;;
    list)
        display_header
        list_sessions
        ;;
    start)
        if [[ -n "$ARG" ]]; then
            start_session "$ARG"
        else
            log_error "Usage: $0 start <session-name>"
        fi
        ;;
    stop)
        if [[ -n "$ARG" ]]; then
            stop_session "$ARG"
        else
            log_error "Usage: $0 stop <session-name>"
        fi
        ;;
    stop-all)
        stop_all_sessions
        ;;
    ""|menu)
        main_menu
        ;;
    *)
        echo "Usage: $0 [command]"
        echo
        echo "Commands:"
        echo "  (none)    Launch interactive menu"
        echo "  create    Create new session"
        echo "  list      List all sessions"
        echo "  start     Start a session"
        echo "  stop      Stop a session"
        echo "  stop-all  Stop all sessions"
        ;;
esac
