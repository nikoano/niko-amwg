#!/bin/bash
# Сервер AmneziaWG поколения 3 (сейчас 3.1) на bare metal: официальные пакеты
# Amnezia, ядерный модуль, конфиг интерфейса с полной обфускацией и утилита
# управления клиентами amwg. Ни докера, ни userspace-реализации на go.
#
#   curl -fsSL <raw>/install.sh | bash -s -- --endpoint 1.2.3.4
#   bash install.sh --port 443 --subnet 10.9.9.0/24 --client phone
#
# Скрипт НЕинтерактивный: при запуске через пайп спрашивать нечего, всё задаётся
# флагами и переменными окружения. Повторный запуск не трогает существующий
# конфиг интерфейса (обновит только пакеты и amwg) — перегенерить с нуля
# заставляет --force-config, и тогда все старые клиентские конфиги протухают.
set -euo pipefail

readonly SELF="niko-amwg install.sh"
readonly PPA_KEY_FPR="75C9DD72C799870E310542E24166F2C257290828"
readonly PPA_URL="https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu"
# Серии, для которых в PPA лежат сборки поколения 3.1 (проверено по launchpad api).
# Для всего остального берётся ближайшая: пакет tools — обычный C-бинарь, а модуль
# всё равно собирается dkms'ом под твоё ядро.
readonly PPA_SERIES_OK="focal jammy noble"
readonly TOOLS_REPO="https://github.com/amnezia-vpn/amneziawg-tools.git"
readonly KMOD_REPO="https://github.com/amnezia-vpn/amneziawg-linux-kernel-module.git"
readonly CONF_DIR="/etc/amnezia/amneziawg"
readonly H_BAND=536870910

repo_raw="${AWG_REPO_RAW:-https://raw.githubusercontent.com/nikoano/niko-amwg/master}"
iface="${AWG_IFACE:-awg0}"
port="${AWG_PORT:-443}"
subnet="${AWG_SUBNET:-10.9.9.0/24}"
dns="${AWG_DNS:-1.1.1.1,1.0.0.1}"
endpoint="${AWG_ENDPOINT:-}"
wan="${AWG_WAN:-}"
client_mtu="${AWG_CLIENT_MTU:-1280}"
keepalive="${AWG_KEEPALIVE:-25}"
allowed_ips="${AWG_ALLOWED_IPS:-0.0.0.0/0, ::/0}"
first_client="${AWG_FIRST_CLIENT:-client1}"
awg_major="${AWG_MAJOR:-3}"
amwg_src="${AMWG_SRC:-}"
from_source=false
single_headers=false
timings=true
hold=true
stats_timer=true
force_config=false
purge_packages=false
assume_yes=false
action=install

usage() {
	cat <<'USAGE'
Установка сервера AmneziaWG 3.x.

  --endpoint HOST      адрес, по которому клиенты придут (по умолчанию — внешний ip)
  --port N             udp-порт [443]
  --iface NAME         имя интерфейса [awg0]
  --subnet CIDR        подсеть туннеля [10.9.9.0/24]
  --dns A,B            DNS для клиентов [1.1.1.1,1.0.0.1]
  --wan IFACE          внешний интерфейс для NAT [определяется по default route]
  --client-mtu N       MTU в клиентских конфигах [1280]
  --keepalive N        PersistentKeepalive [25]
  --allowed-ips STR    AllowedIPs клиента ["0.0.0.0/0, ::/0"]
  --client NAME        завести первого клиента [client1], "" — не заводить
  --from-source        собрать tools и модуль из исходников, минуя PPA
  --single-headers     H1-H4 одиночными числами вместо диапазонов (для старых клиентов)
  --no-timings         не писать RekeyAfterTime и прочие тайминги 3.0
  --no-hold            не фиксировать версии пакетов (apt-mark hold)
  --no-stats-timer     не ставить таймер накопления трафика
  --force-config       перегенерить конфиг интерфейса (все клиенты пойдут перевыпускаться)
  --amwg PATH|URL    откуда взять amwg.py
  --uninstall --yes    снести всё поставленное (с бэкапом ключей в /root)
  --purge              вместе с --uninstall снести и пакеты amneziawg
USAGE
}

# ── вывод ────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
	c_red=$'\033[31m'; c_green=$'\033[32m'; c_yellow=$'\033[33m'
	c_cyan=$'\033[36m'; c_grey=$'\033[90m'; c_off=$'\033[0m'
else
	c_red=''; c_green=''; c_yellow=''; c_cyan=''; c_grey=''; c_off=''
fi
step() { printf '\n%s==>%s %s\n' "$c_cyan" "$c_off" "$*"; }
ok() { printf '%s  ok%s %s\n' "$c_green" "$c_off" "$*"; }
info() { printf '%s     %s%s\n' "$c_grey" "$*" "$c_off"; }
warn() { printf '%s  !!%s %s\n' "$c_yellow" "$c_off" "$*" >&2; }
die() { printf '%s  xx%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
	case "$1" in
	--endpoint) endpoint=$2; shift 2 ;;
	--port) port=$2; shift 2 ;;
	--iface) iface=$2; shift 2 ;;
	--subnet) subnet=$2; shift 2 ;;
	--dns) dns=$2; shift 2 ;;
	--wan) wan=$2; shift 2 ;;
	--client-mtu) client_mtu=$2; shift 2 ;;
	--keepalive) keepalive=$2; shift 2 ;;
	--allowed-ips) allowed_ips=$2; shift 2 ;;
	--client) first_client=$2; shift 2 ;;
	--amwg) amwg_src=$2; shift 2 ;;
	--from-source) from_source=true; shift ;;
	--single-headers) single_headers=true; shift ;;
	--no-timings) timings=false; shift ;;
	--no-hold) hold=false; shift ;;
	--no-stats-timer) stats_timer=false; shift ;;
	--force-config) force_config=true; shift ;;
	--uninstall) action=uninstall; shift ;;
	--purge) purge_packages=true; shift ;;
	--yes|-y) assume_yes=true; shift ;;
	-h|--help) usage; exit 0 ;;
	*) usage >&2; die "непонятный аргумент: $1" ;;
	esac
done

tmp=$(mktemp -d /tmp/awg-install.XXXXXX)
trap 'rm -rf "$tmp"' EXIT

script_dir=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
	script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
fi

conf="$CONF_DIR/$iface.conf"

# Диапазон [lo,hi] из /dev/urandom. Не shuf: `shuf -i` на диапазоне в миллиард
# материализует его в памяти, а H1-H4 живут как раз в таких числах.
rnd() {
	local lo=$1 span=$(( $2 - $1 + 1 )) n
	n=$(od -An -N4 -tu4 /dev/urandom | tr -dc '0-9')
	echo $(( lo + n % span ))
}

need_root() { [ "$(id -u)" = 0 ] || die "нужен root"; }

apt_install() {
	DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@" >/dev/null
}

# ============================================================================
#  Снос
# ============================================================================
do_uninstall() {
	need_root
	$assume_yes || die "снос требует --yes: он удаляет $CONF_DIR вместе с ключами"
	local backup
	backup="/root/awg-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
	if [ -d "$CONF_DIR" ]; then
		tar czf "$backup" -C / "${CONF_DIR#/}" 2>/dev/null || true
		chmod 600 "$backup" 2>/dev/null || true
		ok "бэкап конфигов и ключей: $backup"
	fi
	systemctl disable --now "awg-quick@$iface" >/dev/null 2>&1 || true
	systemctl disable --now amwg-poll.timer >/dev/null 2>&1 || true
	rm -f /etc/systemd/system/amwg-poll.service /etc/systemd/system/amwg-poll.timer
	systemctl daemon-reload >/dev/null 2>&1 || true
	rm -rf "$CONF_DIR"
	rm -f /usr/local/bin/amwg /etc/sysctl.d/99-amneziawg.conf
	rm -f /etc/apt/sources.list.d/amnezia-ppa.list /etc/apt/keyrings/amnezia-ppa.gpg
	apt-mark unhold amneziawg amneziawg-dkms amneziawg-tools >/dev/null 2>&1 || true
	if $purge_packages; then
		DEBIAN_FRONTEND=noninteractive apt-get purge -y amneziawg amneziawg-dkms amneziawg-tools >/dev/null || true
	fi
	ok "снесено"
	exit 0
}

# ============================================================================
#  Пакеты AmneziaWG
# ============================================================================
pick_series() {
	local codename="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
	case " $PPA_SERIES_OK " in
	*" $codename "*) echo "$codename"; return ;;
	esac
	case "${ID:-}" in
	ubuntu|linuxmint|pop|neon|zorin|elementary) echo noble ;;
	*) echo focal ;;
	esac
}

add_repo() {
	local series=$1
	install -d -m 0755 /etc/apt/keyrings
	curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x$PPA_KEY_FPR" \
		-o "$tmp/amnezia.asc" || die "не скачался ключ PPA"
	local got
	got=$(gpg --show-keys --with-colons "$tmp/amnezia.asc" 2>/dev/null |
		awk -F: '/^fpr:/{print $10; exit}')
	[ "$got" = "$PPA_KEY_FPR" ] || die "отпечаток ключа PPA не сошёлся: '$got'"
	gpg --dearmor <"$tmp/amnezia.asc" >/etc/apt/keyrings/amnezia-ppa.gpg
	chmod 0644 /etc/apt/keyrings/amnezia-ppa.gpg
	# deb-src сознательно нет: он нужен только тем, кто пересобирает сами пакеты,
	# а лишняя строка в sources ломает apt update там, где до неё не достучаться
	printf 'deb [signed-by=/etc/apt/keyrings/amnezia-ppa.gpg] %s %s main\n' \
		"$PPA_URL" "$series" >/etc/apt/sources.list.d/amnezia-ppa.list
	apt-get update -qq
	ok "репозиторий amnezia (серия $series), ключ $PPA_KEY_FPR"
}

install_headers() {
	apt_install "linux-headers-$(uname -r)" 2>/dev/null ||
		apt_install linux-headers-generic 2>/dev/null ||
		warn "не встали заголовки ядра — dkms соберёт модуль только с ними"
}

install_from_repo() {
	install_headers
	apt_install amneziawg amneziawg-dkms
}

install_from_source() {
	step "сборка из исходников"
	warn "модуль собирается dkms'ом; на ядрах 5.6+ ему может потребоваться полное"
	warn "дерево исходников ядра, а не только заголовки — см. README, раздел про сборку"
	apt_install git build-essential dkms "linux-headers-$(uname -r)" pkg-config
	rm -rf "$tmp/tools" "$tmp/kmod"
	git clone --depth 1 "$TOOLS_REPO" "$tmp/tools" >/dev/null 2>&1 || die "не склонировался $TOOLS_REPO"
	make -C "$tmp/tools/src" -j"$(nproc)" >/dev/null || die "не собрались amneziawg-tools"
	make -C "$tmp/tools/src" install >/dev/null || die "не поставились amneziawg-tools"
	git clone --depth 1 "$KMOD_REPO" "$tmp/kmod" >/dev/null 2>&1 || die "не склонировался $KMOD_REPO"
	dkms remove -m amneziawg -v 1.0.0 --all >/dev/null 2>&1 || true
	make -C "$tmp/kmod/src" dkms-install >/dev/null || die "dkms-install не прошёл"
	dkms add -m amneziawg -v 1.0.0 >/dev/null 2>&1 || true
	dkms build -m amneziawg -v 1.0.0 >/dev/null || die "модуль не собрался (см. /var/lib/dkms/amneziawg/1.0.0/build/make.log)"
	dkms install -m amneziawg -v 1.0.0 --force >/dev/null || die "модуль не поставился"
	depmod -a
}

major_of() { echo "${1%%.*}"; }

tools_version() { awg --version 2>/dev/null | sed -n 's/^amneziawg-tools v\([0-9][0-9.]*\).*/\1/p'; }
kmod_version() { modinfo -F version amneziawg 2>/dev/null | head -1; }

check_versions() {
	local tv kv
	tv=$(tools_version)
	[ -n "$tv" ] || die "awg не отвечает на --version — tools не поставились"
	[ "$(major_of "$tv")" = "$awg_major" ] ||
		die "amneziawg-tools $tv, а нужно поколение $awg_major (--from-source или AWG_MAJOR=)"
	modprobe amneziawg 2>/dev/null || true
	kv=$(kmod_version)
	if [ -z "$kv" ]; then
		if command -v mokutil >/dev/null && mokutil --sb-state 2>/dev/null | grep -qi enabled; then
			die "модуль amneziawg не грузится, и включён Secure Boot — dkms-модуль надо подписать (mokutil --import) либо выключить SB"
		fi
		die "модуль amneziawg не загрузился: dkms status; journalctl -k | tail"
	fi
	[ "$(major_of "$kv")" = "$awg_major" ] ||
		die "модуль ядра $kv, а нужно поколение $awg_major"
	ok "tools $tv, модуль ядра $kv"
}

versions_ok() {
	local tv kv
	tv=$(tools_version)
	[ -n "$tv" ] && [ "$(major_of "$tv")" = "$awg_major" ] || return 1
	modprobe amneziawg 2>/dev/null || true
	kv=$(kmod_version)
	[ -n "$kv" ] && [ "$(major_of "$kv")" = "$awg_major" ]
}

# ============================================================================
#  Хост: sysctl, NAT, сеть
# ============================================================================
setup_sysctl() {
	{
		echo "# AmneziaWG: форвардинг, очередь и буферы. Положил $SELF"
		echo "net.ipv4.ip_forward = 1"
		[ -d /proc/sys/net/ipv6 ] && echo "net.ipv6.conf.all.forwarding = 1"
		echo "net.core.default_qdisc = fq"
		echo "net.ipv4.tcp_congestion_control = bbr"
		# udp-буферы: под нагрузкой ядро иначе роняет пакеты в очереди сокета
		echo "net.core.rmem_max = 2500000"
		echo "net.core.wmem_max = 2500000"
	} >/etc/sysctl.d/99-amneziawg.conf
	sysctl -q --system >/dev/null 2>&1 || warn "sysctl --system поругался, проверь руками"
	ok "sysctl: ip_forward, bbr+fq, udp-буферы"
}

detect_wan() {
	ip -4 route show default 2>/dev/null |
		awk '{for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit }}'
}

detect_endpoint() {
	local url ip=""
	for url in https://ifconfig.me/ip https://api.ipify.org https://ipv4.icanhazip.com; do
		ip=$(curl -4 -fsS --max-time 8 "$url" 2>/dev/null | tr -d '[:space:]') || ip=""
		case "$ip" in
		'' | *[!0-9.]*) ip="" ;;
		*) echo "$ip"; return 0 ;;
		esac
	done
	ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1
}

check_port_free() {
	command -v ss >/dev/null || return 0
	if ss -lunH 2>/dev/null | awk '{print $5}' | grep -qE "[:.]$port\$"; then
		die "udp/$port уже занят: ss -lunp | grep :$port  (или --port другой)"
	fi
}

# ============================================================================
#  Конфиг интерфейса
# ============================================================================
# Полоса для H1-H4: диапазоны не должны пересекаться между собой, поэтому
# пространство 5..2147483647 режется на четыре равные части, и каждый заголовок
# живёт в своей. Ширина диапазона — это фича 3.0: заголовок гуляет от пакета к
# пакету, и статичной сигнатуры для DPI не остаётся.
h_value() {
	local base=$((5 + $1 * H_BAND)) lo hi
	lo=$(rnd "$base" $((base + H_BAND - 8000)))
	if $single_headers; then
		echo "$lo"
	else
		hi=$((lo + $(rnd 500 5000)))
		echo "$lo-$hi"
	fi
}

write_server_conf() {
	local prefix=${subnet#*/} server_ip=$1
	local priv hpk jc jmin jmax s1 s2 s3 s4 cpa
	priv=$(awg genkey)
	# HeaderProtectionKey — ровно такой же ключ, как остальные: 32 байта в base64
	# (в ядре это CHACHA_KEY_SIZE, парсится тем же parse_key). Не hex, вопреки
	# части статей в интернете
	hpk=$(awg genpsk)
	jc=$(rnd 4 12); jmin=$(rnd 8 24); jmax=$(rnd 64 320)
	# S1..S4 >= 12 обязаны быть при включённой защите заголовков
	# (HEADER_PROTECTION_NONCE_SIZE), и отдельно S1 + 56 != S2
	s1=$(rnd 15 150); s2=$(rnd 15 150)
	while [ $((s1 + 56)) -eq "$s2" ]; do s2=$(rnd 15 150); done
	s3=$(rnd 15 150); s4=$(rnd 15 150)
	cpa="$(rnd 8 32)-$(rnd 48 96)"

	install -d -m 0700 "$CONF_DIR"
	# приватный ключ не должен и мгновения полежать с дефолтными правами,
	# поэтому umask, а не chmod после записи; дальше по скрипту он не нужен
	local old_umask
	old_umask=$(umask)
	umask 077
	{
		echo "# AmneziaWG $awg_major.x, сгенерирован $SELF $(date -Is)"
		echo "# Секции [Peer] ниже пишет amwg — правки в них перетрутся."
		echo "# Параметры обфускации обязаны совпадать с клиентом; их копирует"
		echo "# в клиентские конфиги amwg, руками ничего сверять не надо."
		echo "[Interface]"
		echo "PrivateKey = $priv"
		echo "Address = $server_ip/$prefix"
		echo "ListenPort = $port"
		echo "PostUp = iptables -t nat -I POSTROUTING 1 -s $subnet -o $wan -j MASQUERADE; iptables -I FORWARD 1 -i %i -j ACCEPT; iptables -I FORWARD 1 -o %i -j ACCEPT; iptables -I INPUT 1 -p udp --dport $port -j ACCEPT"
		echo "PostDown = iptables -t nat -D POSTROUTING -s $subnet -o $wan -j MASQUERADE; iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -D INPUT -p udp --dport $port -j ACCEPT"
		echo
		echo "# --- 1.0: мусорные пакеты перед handshake (у клиентов свои значения) ---"
		echo "Jc = $jc"
		echo "Jmin = $jmin"
		echo "Jmax = $jmax"
		echo
		echo "# --- 1.0/1.5: мусор внутри служебных пакетов ---"
		echo "S1 = $s1"
		echo "S2 = $s2"
		echo "S3 = $s3"
		echo "S4 = $s4"
		echo
		echo "# --- 2.0: типы сообщений диапазонами, между собой не пересекаются ---"
		echo "H1 = $(h_value 0)"
		echo "H2 = $(h_value 1)"
		echo "H3 = $(h_value 2)"
		echo "H4 = $(h_value 3)"
		echo
		echo "# --- 3.0: ChaCha20 поверх заголовков и паддинг полезной нагрузки ---"
		echo "HeaderProtectionKey = $hpk"
		echo "ContentPaddingAddition = $cpa"
		if $timings; then
			echo
			echo "# --- 3.0: тайминги диапазонами (дефолты ядра 120/5/180/10/18) ---"
			echo "RekeyAfterTime = 110-130"
			echo "RekeyTimeout = 5-7"
			echo "RejectAfterTime = 175-190"
			echo "KeepaliveTimeout = 8-12"
			echo "MaxHandshakeAttempts = 16-20"
		fi
		echo
		echo "# --- 3.1: ответ на поведенческий анализ трафика ---"
		echo "RandomTrailers = on"
		echo "DisableCookies = on"
		echo
		echo "# --- сигнатурные пакеты 1.5: их надо писать руками под конкретную"
		echo "# маскировку (<b 0x..> байты, <r N> рандом, <t> таймстемп), поэтому"
		echo "# по умолчанию выключены ---"
		echo "# I1 = <b 0x0100>"
	} >"$conf"
	chmod 600 "$conf"
	umask "$old_umask"
	ok "конфиг интерфейса: $conf"
}

# ============================================================================
#  amwg
# ============================================================================
install_amwg() {
	local src=""
	if [ -n "$amwg_src" ]; then
		case "$amwg_src" in
		http://* | https://*)
			curl -fsSL "$amwg_src" -o "$tmp/amwg.py" || die "не скачался $amwg_src"
			src="$tmp/amwg.py" ;;
		*) src="$amwg_src" ;;
		esac
	elif [ -n "$script_dir" ] && [ -f "$script_dir/amwg.py" ]; then
		src="$script_dir/amwg.py"
	else
		curl -fsSL "$repo_raw/amwg.py" -o "$tmp/amwg.py" ||
			die "не скачался $repo_raw/amwg.py — задай --amwg или AWG_REPO_RAW"
		src="$tmp/amwg.py"
	fi
	# Закачку могут порезать посередине, и тогда «утилита» окажется половиной
	# файла: проверяем синтаксис до установки, а не после первого запуска
	python3 -c "import ast, sys; ast.parse(open(sys.argv[1], encoding='utf-8').read())" "$src" ||
		die "amwg.py приехал битым ($(wc -c <"$src") байт)"
	install -m 0755 "$src" /usr/local/bin/amwg
	ok "утилита: /usr/local/bin/amwg"
}

install_stats_timer() {
	cat >/etc/systemd/system/amwg-poll.service <<'UNIT'
[Unit]
Description=amwg: накопление трафика клиентов AmneziaWG
Documentation=man:awg(8)

[Service]
Type=oneshot
ExecStart=/usr/local/bin/amwg poll
UNIT
	cat >/etc/systemd/system/amwg-poll.timer <<'UNIT'
[Unit]
Description=amwg poll: копит трафик клиентов AmneziaWG
# счётчики ядра обнуляются при рестарте интерфейса, складывать их можно только снаружи

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
UNIT
	chmod 0644 /etc/systemd/system/amwg-poll.service /etc/systemd/system/amwg-poll.timer
	systemctl daemon-reload
	systemctl enable --now amwg-poll.timer >/dev/null 2>&1 ||
		warn "таймер amwg-poll не включился"
	ok "таймер накопления трафика: amwg-poll.timer (раз в 5 минут)"
}

# ============================================================================
#  Главное
# ============================================================================
summary() {
	local created=$1
	cat <<INFO

$(printf '%s' "$c_green")Готово.$(printf '%s' "$c_off")

  сервер        $endpoint:$port/udp, интерфейс $iface, подсеть $subnet
  конфиг        $conf
  клиенты       $CONF_DIR/amwg/state.json (ключи, 0600)
  трафик        $CONF_DIR/amwg/traffic.json, копит amwg-poll.timer

  amwg                      меню (стрелки, цифры, пробел, q)
  amwg add <имя> --qr       новый клиент и qr сразу в терминал
  amwg list -v              кто есть, когда подключался, сколько скачал
  amwg show <имя> --png f   qr картинкой, если терминал не тянет
  amwg disable <имя>        снять с интерфейса, не удаляя
  amwg stats --watch        живой трафик

  журнал        journalctl -u awg-quick@$iface -n 50
  перечитать    systemctl restart awg-quick@$iface
INFO
	if [ -n "$created" ]; then
		printf '\n  Конфиг первого клиента (%s) — выше в выводе amwg add.\n' "$created"
	fi
}

main() {
	need_root
	[ "$action" = uninstall ] && do_uninstall
	command -v apt-get >/dev/null ||
		die "поддерживаются apt-дистрибутивы; на RHEL/Fedora: dnf copr enable amneziavpn/amneziawg && dnf install amneziawg-dkms amneziawg-tools, дальше конфиг руками по README"

	# shellcheck disable=SC1091
	if [ -r /etc/os-release ]; then . /etc/os-release; fi

	step "базовые пакеты"
	apt-get update -qq
	apt_install ca-certificates curl gnupg iproute2 iptables qrencode python3 tar
	ok "${PRETTY_NAME:-${ID:-linux}}, ядро $(uname -r), $(dpkg --print-architecture)"

	step "AmneziaWG поколения $awg_major"
	if $from_source; then
		install_from_source
	else
		add_repo "$(pick_series)"
		install_from_repo || warn "apt поругался, проверяю что вышло"
		if ! versions_ok; then
			warn "в репозитории не поколение $awg_major — собираю из исходников"
			install_from_source
		fi
		if $hold; then
			apt-mark hold amneziawg amneziawg-dkms amneziawg-tools >/dev/null 2>&1 &&
				info "версии зафиксированы (apt-mark unhold — снять)"
		fi
	fi
	check_versions

	step "хост"
	setup_sysctl
	[ -n "$wan" ] || wan=$(detect_wan)
	[ -n "$wan" ] || die "не понял внешний интерфейс — задай --wan"
	[ -n "$endpoint" ] || endpoint=$(detect_endpoint)
	[ -n "$endpoint" ] || die "не понял внешний адрес — задай --endpoint"
	ok "внешний интерфейс $wan, клиенты придут на $endpoint:$port"
	if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "^Status: active"; then
		ufw allow "$port/udp" >/dev/null 2>&1 && ok "ufw: открыт $port/udp"
	fi

	local server_ip
	server_ip=$(python3 -c 'import ipaddress, sys; print(next(ipaddress.ip_network(sys.argv[1], strict=False).hosts()))' "$subnet")

	step "конфиг интерфейса"
	if [ -f "$conf" ] && ! $force_config; then
		info "$conf уже есть — не трогаю (--force-config перегенерит, и тогда всем"
		info "клиентам понадобятся новые конфиги: сменятся ключ сервера и обфускация)"
	else
		[ -f "$conf" ] && cp -a "$conf" "$conf.bak-$(date +%Y%m%d-%H%M%S)"
		check_port_free
		write_server_conf "$server_ip"
	fi

	step "утилита управления"
	install_amwg
	local created=""
	if [ ! -f "$CONF_DIR/amwg/state.json" ]; then
		amwg init --iface "$iface" --endpoint "$endpoint:$port" --subnet "$subnet" \
			--server-ip "$server_ip" --dns "$dns" --mtu "$client_mtu" \
			--keepalive "$keepalive" --allowed-ips "$allowed_ips"
	else
		amwg server --endpoint "$endpoint:$port" >/dev/null
		info "клиенты на месте: $(amwg list --json | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))') шт."
	fi
	if $stats_timer; then install_stats_timer; fi

	step "запуск"
	systemctl enable "awg-quick@$iface" >/dev/null 2>&1 ||
		die "нет юнита awg-quick@ — tools встали криво"
	systemctl restart "awg-quick@$iface" ||
		die "интерфейс не поднялся: journalctl -u awg-quick@$iface -n 40"
	awg show "$iface" >/dev/null || die "awg show $iface пустой"
	ok "интерфейс $iface поднят, автозапуск включён"
	amwg apply >/dev/null

	if [ -n "$first_client" ] && ! amwg list --json | grep -q "\"name\": \"$first_client\""; then
		step "первый клиент"
		# сперва конфиг текстом (его можно скопировать), потом qr — телефоном
		amwg add "$first_client"
		if command -v qrencode >/dev/null && [ -t 1 ]; then
			amwg show "$first_client" --qr
		fi
		created=$first_client
	fi

	summary "$created"
}

main "$@"
