#!/bin/bash
# monitor.sh - TCPDump Super Colorido

# Configurações
DELAY=${1:-0.1}
INTERFACE=${2:-any}

# Cores intensas e variadas
RED=$(tput setaf 1)
BRIGHT_RED=$(tput setaf 9)
GREEN=$(tput setaf 2)
BRIGHT_GREEN=$(tput setaf 10)
YELLOW=$(tput setaf 3)
BRIGHT_YELLOW=$(tput setaf 11)
BLUE=$(tput setaf 4)
BRIGHT_BLUE=$(tput setaf 12)
PURPLE=$(tput setaf 5)
BRIGHT_PURPLE=$(tput setaf 13)
CYAN=$(tput setaf 6)
BRIGHT_CYAN=$(tput setaf 14)
WHITE=$(tput setaf 7)
BRIGHT_WHITE=$(tput bold)$(tput setaf 7)
ORANGE=$(tput setaf 208 2>/dev/null || tput setaf 3)
MAGENTA=$(tput setaf 201 2>/dev/null || tput setaf 5)
GRAY=$(tput setaf 8)
BOLD=$(tput bold)
NC=$(tput sgr0)

# IP local
LOCAL_IP=$(ip route get 1 2>/dev/null | awk '{print $7; exit}')
LOCAL_NETWORK=$(echo "$LOCAL_IP" | cut -d. -f1-3)

echo "${BRIGHT_CYAN}${BOLD}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                   MONITOR DE REDE SUPER COLORIDO            ║"
echo "║                IP Local: $LOCAL_IP               ║"
echo "╚══════════════════════════════════════════════════════════════╝${NC}"
echo "${YELLOW}Interface: $INTERFACE | Delay: ${DELAY}s | ${GREEN}⬆ OUT ${RED}⬇ IN ${BLUE}↔ LOCAL${NC}"
echo ""

# Função para análise de tráfego
analyze_traffic() {
    local src_ip="$1" dst_ip="$2"
    
    is_local_ip() {
        local ip="$1"
        [[ "$ip" == "$LOCAL_IP" ]] && return 0
        [[ "$ip" =~ ^$LOCAL_NETWORK\.[0-9]+$ ]] && return 0
        [[ "$ip" == "127.0.0.1" ]] && return 0
        return 1
    }
    
    if is_local_ip "$src_ip" && ! is_local_ip "$dst_ip"; then
        echo "${BRIGHT_GREEN}OUTBOUND${NC}" "${BRIGHT_GREEN}EXTERNAL${NC}" "🟢"
    elif ! is_local_ip "$src_ip" && is_local_ip "$dst_ip"; then
        echo "${BRIGHT_RED}INCOMING${NC}" "${BRIGHT_RED}EXTERNAL${NC}" "🔴"
    elif is_local_ip "$src_ip" && is_local_ip "$dst_ip"; then
        echo "${BRIGHT_BLUE}INTERNAL${NC}" "${BRIGHT_BLUE}LOCAL${NC}" "🔵"
    else
        echo "${GRAY}UNKNOWN${NC}" "${GRAY}EXTERNAL${NC}" "⚫"
    fi
}

# Função principal de coloração SUPER COLORIDA
colorize_line() {
    local line="$1"
    
    # Extrair IPs
    local src_ip dst_ip
    src_ip=$(echo "$line" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
    dst_ip=$(echo "$line" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -2 | tail -1)
    
    # Analisar tráfego
    local direction network_type emoji
    read direction network_type emoji < <(analyze_traffic "$src_ip" "$dst_ip")
    
    # Colorir TUDO com awk
    colored_line=$(echo "$line" | awk \
        -v red="$RED" -v bred="$BRIGHT_RED" -v green="$GREEN" -v bgreen="$BRIGHT_GREEN" \
        -v yellow="$YELLOW" -v byellow="$BRIGHT_YELLOW" -v blue="$BLUE" -v bblue="$BRIGHT_BLUE" \
        -v purple="$PURPLE" -v bpurple="$BRIGHT_PURPLE" -v cyan="$CYAN" -v bcyan="$BRIGHT_CYAN" \
        -v white="$WHITE" -v bwhite="$BRIGHT_WHITE" -v orange="$ORANGE" -v magenta="$MAGENTA" \
        -v gray="$GRAY" -v nc="$NC" \
        -v src_ip="$src_ip" -v dst_ip="$dst_ip" \
        -v local_ip="$LOCAL_IP" -v local_net="$LOCAL_NETWORK" '
        
        function is_local(ip) {
            return ip == local_ip || index(ip, local_net ".") == 1 || ip == "127.0.0.1"
        }
        
        {
            # 🎨 COLORIR IPs - DESTAQUE MÁXIMO
            gsub(src_ip, (is_local(src_ip) ? bgreen "[" src_ip "]" nc : bred "[" src_ip "]" nc))
            gsub(dst_ip, (is_local(dst_ip) ? bgreen "[" dst_ip "]" nc : bred "[" dst_ip "]" nc))
            
            # 🔥 PROTOCOLOS - SUPER DESTAQUE
            gsub(/IP/, bwhite "🌐 IP" nc)
            gsub(/ARP/, bpurple "🔗 ARP" nc)
            gsub(/TCP/, byellow "🔷 TCP" nc)
            gsub(/UDP/, bblue "🔶 UDP" nc)
            gsub(/ICMP/, bred "💠 ICMP" nc)
            gsub(/DNS/, bpurple "🌍 DNS" nc)
            gsub(/HTTP/, bgreen "🌐 HTTP" nc)
            gsub(/HTTPS/, bgreen "🔐 HTTPS" nc)
            gsub(/TLS/, bgreen "🔒 TLS" nc)
            gsub(/SSL/, bgreen "🔒 SSL" nc)
            gsub(/SSH/, bcyan "🖥️ SSH" nc)
            gsub(/FTP/, bwhite "📁 FTP" nc)
            gsub(/SMTP/, orange "📧 SMTP" nc)
            gsub(/POP3/, orange "📥 POP3" nc)
            gsub(/IMAP/, orange "📨 IMAP" nc)
            gsub(/DHCP/, magenta "🔄 DHCP" nc)
            gsub(/NTP/, cyan "⏰ NTP" nc)
            
            # 🚩 FLAGS TCP - COLORIDAS
            gsub(/Flags \[S\]/, bred "🚩 SYN" nc)
            gsub(/Flags \[\.\]/, bgreen "✅ ACK" nc)
            gsub(/Flags \[P\]/, byellow "📤 PUSH" nc)
            gsub(/Flags \[F\]/, bred "🏁 FIN" nc)
            gsub(/Flags \[R\]/, bred "🛑 RST" nc)
            gsub(/Flags \[U\]/, bred "🚨 URG" nc)
            
            # 🔢 PORTAS IMPORTANTES - DESTAQUE
            gsub(/:443/, ":" bgreen "🔐443" nc)
            gsub(/:80/, ":" bgreen "🌐80" nc)
            gsub(/:22/, ":" bcyan "🖥️22" nc)
            gsub(/:53/, ":" bpurple "🌍53" nc)
            gsub(/:25/, ":" orange "📧25" nc)
            gsub(/:587/, ":" orange "📧587" nc)
            gsub(/:993/, ":" orange "📨993" nc)
            gsub(/:995/, ":" orange "📥995" nc)
            gsub(/:110/, ":" orange "📥110" nc)
            gsub(/:143/, ":" orange "📨143" nc)
            gsub(/:21/, ":" bwhite "📁21" nc)
            gsub(/:23/, ":" bwhite "💻23" nc)
            gsub(/:123/, ":" cyan "⏰123" nc)
            gsub(/:67/, ":" magenta "🔄67" nc)
            gsub(/:68/, ":" magenta "🔄68" nc)
            
            # 📊 CAMPOS DE REDE - COLORIDOS
            if (match($0, /length [0-9]+/)) {
                len_str = substr($0, RSTART, RLENGTH)
                gsub(/length [0-9]+/, byellow "📏 " len_str nc)
            }
            if (match($0, /ttl [0-9]+/)) {
                ttl_str = substr($0, RSTART, RLENGTH)
                gsub(/ttl [0-9]+/, bcyan "⏱️ " ttl_str nc)
            }
            if (match($0, /win [0-9]+/)) {
                win_str = substr($0, RSTART, RLENGTH)
                gsub(/win [0-9]+/, bgreen "🪟 " win_str nc)
            }
            if (match($0, /seq [0-9]+:[0-9]+|seq [0-9]+/)) {
                seq_str = substr($0, RSTART, RLENGTH)
                gsub(/seq [0-9]+:[0-9]+|seq [0-9]+/, orange "🔢 " seq_str nc)
            }
            if (match($0, /ack [0-9]+/)) {
                ack_str = substr($0, RSTART, RLENGTH)
                gsub(/ack [0-9]+/, orange "📨 " ack_str nc)
            }
            if (match($0, /id [0-9]+/)) {
                id_str = substr($0, RSTART, RLENGTH)
                gsub(/id [0-9]+/, magenta "🆔 " id_str nc)
            }
            if (match($0, /mf|df/)) {
                flags_str = substr($0, RSTART, RLENGTH)
                gsub(/mf|df/, bred "🚩" flags_str nc)
            }
            
            # 📍 OUTROS CAMPOS
            gsub(/options/, bpurple "⚙️ options" nc)
            gsub(/mss [0-9]+/, bpurple "📦 mss " substr($0, RSTART+4, RLENGTH-4) nc)
            gsub(/wscale [0-9]+/, bpurple "📊 wscale " substr($0, RSTART+7, RLENGTH-7) nc)
            gsub(/sackOK/, bgreen "✅ sackOK" nc)
            gsub(/nop/, gray "⚪ nop" nc)
            
            # ➡️ SETA DE DIREÇÃO
            gsub(/>/, bwhite " ➡ " nc)
            
            # 🏷️ TAGS ESPECIAIS
            gsub(/\[/, bwhite "[" nc)
            gsub(/\]/, bwhite "]" nc)
            
            print
        }')
    
    echo "$emoji $direction $network_type $colored_line"
}

# Estatísticas
IN_COUNT=0 OUT_COUNT=0 LOCAL_COUNT=0 TOTAL_COUNT=0

echo "${BOLD}${WHITE}INICIANDO CAPTURA...${NC}"
echo "${GRAY}════════════════════════════════════════════════════════════════${NC}"

# Capturar tráfego
sudo tcpdump -n -l -i "$INTERFACE" 2>/dev/null | while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    
    # Limpar timestamp do tcpdump
    clean_line=$(echo "$line" | sed -E 's/^[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+ //')
    
    # Extrair IPs para análise
    src_ip=$(echo "$clean_line" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
    dst_ip=$(echo "$clean_line" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -2 | tail -1)
    
    # Atualizar estatísticas
    if [[ -n "$src_ip" && -n "$dst_ip" ]]; then
        read direction network_type emoji < <(analyze_traffic "$src_ip" "$dst_ip")
        case "$direction" in
            *OUTBOUND*) ((OUT_COUNT++)) ;;
            *INCOMING*) ((IN_COUNT++)) ;;
            *INTERNAL*) ((LOCAL_COUNT++)) ;;
        esac
        ((TOTAL_COUNT++))
    fi
    
    # Colorir linha
    colored_line=$(colorize_line "$clean_line")
    
    # Timestamp colorido
    timestamp=$(date '+%H:%M:%S')
    
    # Header de estatísticas a cada 15 linhas
    if (( TOTAL_COUNT % 15 == 0 )); then
        echo "${BWHITE}${BOLD}"
        echo "╔══════════════════════════════════════════════════════════════╗"
        printf "║ ${GREEN}⬆ OUT: %-4d ${RED}⬇ IN: %-4d ${BLUE}↔ LOCAL: %-4d ${YELLOW}📊 TOTAL: %-4d ║\n" \
               $OUT_COUNT $IN_COUNT $LOCAL_COUNT $TOTAL_COUNT
        echo "╚══════════════════════════════════════════════════════════════╝${NC}"
    fi
    
    # Output final
    printf "${BOLD}${WHITE}[${timestamp}]${NC} ${colored_line}\n"
    
    sleep "$DELAY"
done
