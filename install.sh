#!/bin/bash
# Сервер AmneziaWG поколения 3 (сейчас 3.1) на bare metal: официальные пакеты
# Amnezia, ядерный модуль, конфиг интерфейса с полной обфускацией и утилита
# управления клиентами amwg. Ни докера, ни userspace-реализации на go.
#
#   curl -fsSL https://raw.githubusercontent.com/nikoano/niko-amwg/master/install.sh | bash -s -- --endpoint 1.2.3.4
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
# Серии, под которые в PPA опубликованы tools ПОКОЛЕНИЯ 3.1 (сверено с launchpad
# api по коммиту в версии пакета: ee0f0a9). focal/bionic/xenial застряли на 3.0
# (9f70177) — там нет RandomTrailers и DisableCookies, и наш конфиг на них не
# встанет; модуль (amneziawg-dkms 3c38e16) при этом свежий во всех сериях.
# Для всего остального берётся ближайшая подходящая, а не «хоть какая-то».
readonly PPA_SERIES_OK="jammy noble"
readonly TOOLS_REPO="https://github.com/amnezia-vpn/amneziawg-tools.git"
readonly KMOD_REPO="https://github.com/amnezia-vpn/amneziawg-linux-kernel-module.git"
readonly GO_REPO="https://github.com/amnezia-vpn/amneziawg-go.git"
readonly CONF_DIR="/etc/amnezia/amneziawg"
readonly H_BAND=536870910

repo_raw="${AWG_REPO_RAW:-https://raw.githubusercontent.com/nikoano/niko-amwg/master}"
iface="${AWG_IFACE:-awg0}"
port="${AWG_PORT:-443}"
port_explicit=false
[ -n "${AWG_PORT:-}" ] && port_explicit=true
subnet="${AWG_SUBNET:-10.9.9.0/24}"
dns="${AWG_DNS:-1.1.1.1,1.0.0.1}"
endpoint="${AWG_ENDPOINT:-}"
wan="${AWG_WAN:-}"
client_mtu="${AWG_CLIENT_MTU:-1280}"
keepalive="${AWG_KEEPALIVE:-25}"
allowed_ips="${AWG_ALLOWED_IPS:-0.0.0.0/0, ::/0}"
first_client="${AWG_FIRST_CLIENT:-client1}"
awg_version="${AWG_VERSION:-3.1}"
amwg_src="${AMWG_SRC:-}"
from_source=false
from_repo=false
userspace=false
single_headers=false
timings=true
hold=true
stats_timer=true
force_config=false
ask_input=true
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
  --from-repo          взять пакеты из репозитория niko-amwg (папка debs/),
                       когда официальный PPA недоступен или уехал по версии
  --userspace          вместо ядерного модуля — amneziawg-go (медленнее, но не
                       зависит от ядра: ни dkms, ни заголовков, ни пересборки)
  --single-headers     H1-H4 одиночными числами вместо диапазонов (для старых клиентов)
  --no-timings         не писать RekeyAfterTime и прочие тайминги 3.0
  --no-hold            не фиксировать версии пакетов (apt-mark hold)
  --no-stats-timer     не ставить таймер накопления трафика
  --force-config       перегенерить конфиг интерфейса (все клиенты пойдут перевыпускаться)
  --no-ask             не спрашивать адрес даже в живой консоли
  --amwg PATH|URL      откуда взять amwg.py
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
	--port) port=$2; port_explicit=true; shift 2 ;;
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
	--from-repo) from_repo=true; shift ;;
	--userspace) userspace=true; shift ;;
	--single-headers) single_headers=true; shift ;;
	--no-timings) timings=false; shift ;;
	--no-hold) hold=false; shift ;;
	--no-stats-timer) stats_timer=false; shift ;;
	--force-config) force_config=true; shift ;;
	--no-ask) ask_input=false; shift ;;
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
	systemctl disable --now amwg-ensure-module.service >/dev/null 2>&1 || true
	rm -f /etc/systemd/system/amwg-poll.service /etc/systemd/system/amwg-poll.timer
	rm -f /etc/systemd/system/amwg-ensure-module.service /usr/local/sbin/amwg-ensure-module
	rm -f "/etc/systemd/system/awg-quick@$iface.service.d/10-amwg.conf"
	rmdir "/etc/systemd/system/awg-quick@$iface.service.d" 2>/dev/null || true
	systemctl daemon-reload >/dev/null 2>&1 || true
	rm -rf "$CONF_DIR"
	rm -f /usr/local/bin/amwg /usr/local/bin/amneziawg-go /etc/sysctl.d/99-amneziawg.conf
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
	# jammy — самая старая серия с tools 3.1; её glibc 2.35 старше дебиановской,
	# так что бинарь заводится и на debian 12/13 (проверено в контейнерах)
	case "${ID:-}" in
	ubuntu|linuxmint|pop|neon|zorin|elementary) echo noble ;;
	*) echo jammy ;;
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

# 6.8.0-51-generic → generic, 6.8.0-1021-aws → aws, 6.1.0-18-cloud-amd64 → cloud-amd64
kernel_flavour() { uname -r | sed -n 's/^[0-9][0-9.]*-[0-9]*-\(.*\)$/\1/p'; }

# Ставится МЕТА-пакет, а не linux-headers-$(uname -r): версионный никогда не
# обновится, следующее ядро приедет без заголовков, и dkms будет нечем собирать —
# ровно так vpn и умирает после планового apt upgrade с ребутом.
install_headers() {
	local flavour meta
	flavour=$(kernel_flavour)
	meta=""
	[ -n "$flavour" ] && meta="linux-headers-$flavour"
	if [ -n "$meta" ] && apt_install "$meta"; then
		ok "заголовки ядра: $meta (приезжают вместе с новым ядром)"
	elif apt_install "linux-headers-$(uname -r)"; then
		warn "мета-пакета заголовков не нашлось, поставил только под $(uname -r):"
		warn "после обновления ядра заголовки придётся доставить руками"
	else
		warn "заголовки ядра не встали — dkms не сможет собрать модуль"
	fi
}

install_from_repo() {
	if $userspace; then
		# метапакет amneziawg тянет за собой dkms, а он тут не нужен вовсе
		apt_install amneziawg-tools
		return
	fi
	install_headers
	apt_install amneziawg amneziawg-dkms
}

# Запасной путь на случай, когда PPA недоступен или уехал: те же официальные
# пакеты, но снятые заранее и положенные в репозиторий. Из PPA старые сборки
# ИСЧЕЗАЮТ — вытесненная версия отдаёт 404 уже через недели, так что «поставить
# ту же самую, что и раньше» иначе просто нельзя.
#
# Раскладка в репо — по сериям: debs/<серия>/*.deb плюс SHA256SUMS рядом.
# Из всего комплекта берутся файлы своей архитектуры и arch-independent.
install_from_repo_debs() {
	local series=$1 arch dir="$tmp/debs" sum name got=0
	arch=$(dpkg --print-architecture)

	mkdir -p "$dir"
	curl -fsSL "$repo_raw/debs/$series/SHA256SUMS" -o "$dir/SHA256SUMS" 2>/dev/null ||
		die "в репо нет комплекта под $series (лежат noble и jammy) — тогда --from-source"
	: >"$dir/sums"
	while read -r sum name; do
		case "$name" in
		*_all.deb | *_"$arch".deb) ;;
		*) continue ;;
		esac
		# в userspace ставится только tools: модуль и метапакет ни к чему
		if $userspace; then
			case "$name" in
			amneziawg-tools_*) ;;
			*) continue ;;
			esac
		fi
		curl -fsSL "$repo_raw/debs/$series/$name" -o "$dir/$name" || die "не скачался $name"
		printf '%s  %s\n' "$sum" "$name" >>"$dir/sums"
		got=$((got + 1))
	done <"$dir/SHA256SUMS"
	[ "$got" -gt 0 ] || die "в репо нет пакетов под $series/$arch"
	# Закачку могут порезать посередине — на битом .deb dpkg скажет невнятное,
	# поэтому суммы сверяем до установки
	( cd "$dir" && sha256sum -c --quiet sums ) || die "контрольные суммы пакетов не сошлись"

	if ! $userspace; then
		apt_install dkms perl
		install_headers
	fi
	if ! dpkg -i "$dir"/*.deb >/dev/null 2>&1; then
		DEBIAN_FRONTEND=noninteractive apt-get -f install -y >/dev/null 2>&1 || true
		dpkg -i "$dir"/*.deb >/dev/null || die "пакеты из репо не встали, смотри dpkg -i вручную"
	fi
	ok "пакеты из репозитория niko-amwg: $series/$arch, $got шт."
}

# Реализация на go: тот же протокол в обычном процессе. Готовых бинарей у
# Amnezia нет (в репозитории go нет ни одного релиза), поэтому собираем из
# исходников — это семь секунд и не тянет ничего, кроме компилятора. go.mod
# требует свежий go, но начиная с 1.21 тулчейн доустанавливается сам.
# Клонирование с внятной ошибкой: раньше вывод git уходил в /dev/null, и любая
# сетевая неурядица выглядела одинаково — «не склонировался». GIT_TERMINAL_PROMPT=0
# отдельно: без него git на неудаче лезет спрашивать логин и вешает установку.
git_clone() {
	local err
	err=$(GIT_TERMINAL_PROMPT=0 git clone --depth 1 "$1" "$2" 2>&1) ||
		die "не склонировался $1: $(printf '%s' "$err" | tail -1)"
}

install_userspace_go() {
	step "amneziawg-go"
	apt_install golang-go git
	rm -rf "$tmp/go-src"
	git_clone "$GO_REPO" "$tmp/go-src"
	( cd "$tmp/go-src" && GOTOOLCHAIN=auto GOFLAGS=-buildvcs=false \
		go build -o "$tmp/amneziawg-go" . ) >/dev/null 2>&1 ||
		die "amneziawg-go не собрался (нужен доступ к proxy.golang.org)"
	install -m 0755 "$tmp/amneziawg-go" /usr/local/bin/amneziawg-go
	ok "amneziawg-go: /usr/local/bin/amneziawg-go ($(amneziawg-go --version 2>&1 | head -1))"
}

install_from_source() {
	step "сборка из исходников"
	apt_install git build-essential pkg-config
	rm -rf "$tmp/tools" "$tmp/kmod"
	git_clone "$TOOLS_REPO" "$tmp/tools"
	make -C "$tmp/tools/src" -j"$(nproc)" >/dev/null || die "не собрались amneziawg-tools"
	make -C "$tmp/tools/src" install >/dev/null || die "не поставились amneziawg-tools"
	if $userspace; then
		install_userspace_go
		return
	fi
	warn "модуль собирается dkms'ом; на ядрах 5.6+ ему может потребоваться полное"
	warn "дерево исходников ядра, а не только заголовки — см. README, раздел про сборку"
	apt_install dkms
	install_headers
	git_clone "$KMOD_REPO" "$tmp/kmod"
	dkms remove -m amneziawg -v 1.0.0 --all >/dev/null 2>&1 || true
	make -C "$tmp/kmod/src" dkms-install >/dev/null || die "dkms-install не прошёл"
	dkms add -m amneziawg -v 1.0.0 >/dev/null 2>&1 || true
	dkms build -m amneziawg -v 1.0.0 >/dev/null || die "модуль не собрался (см. /var/lib/dkms/amneziawg/1.0.0/build/make.log)"
	dkms install -m amneziawg -v 1.0.0 --force >/dev/null || die "модуль не поставился"
	depmod -a
}

# Сравнение major.minor: поколения мало. tools 3.0 не знают ключей RandomTrailers
# и DisableCookies, и конфиг с ними просто не применится.
version_ge() {
	local have=$1 want=$2 hmaj hmin wmaj wmin
	hmaj=${have%%.*}; hmin=${have#"$hmaj"}; hmin=${hmin#.}; hmin=${hmin%%.*}
	wmaj=${want%%.*}; wmin=${want#"$wmaj"}; wmin=${wmin#.}; wmin=${wmin%%.*}
	[ -n "$hmin" ] || hmin=0
	[ -n "$wmin" ] || wmin=0
	case "$hmaj$hmin$wmaj$wmin" in
	*[!0-9]*) return 1 ;;
	esac
	[ "$hmaj" -gt "$wmaj" ] || { [ "$hmaj" -eq "$wmaj" ] && [ "$hmin" -ge "$wmin" ]; }
}

tools_version() { awg --version 2>/dev/null | sed -n 's/^amneziawg-tools v\([0-9][0-9.]*\).*/\1/p'; }

# ВНИМАНИЕ: это версия ПАКЕТА, а не поколения протокола. В Makefile модуля жёстко
# зашито WIREGUARD_VERSION = 1.0.0, и оно перебивает version.h с настоящим
# 3.1.20260812, так что и modinfo, и /sys/module показывают 1.0.0 у любой сборки.
# Сравнивать её с 3.1 бессмысленно — годится только для отчёта.
kmod_pkg_version() {
	cat /sys/module/amneziawg/version 2>/dev/null ||
		modinfo -F version amneziawg 2>/dev/null | head -1
}

# Раз версии нет — спрашиваем у самого бэкенда: понимает ли он параметры 3.1.
# Временный интерфейс без порта и адреса, живой awg0 не задет.
probe_iface_create() {
	if $userspace; then
		amneziawg-go "$1" >/dev/null 2>&1
	else
		ip link add "$1" type amneziawg 2>/dev/null
	fi
}

backend_speaks_awg31() {
	local probe="$tmp/probe31.conf" iface=amwgprobe0 rc=0
	{
		echo "[Interface]"
		echo "PrivateKey = $(awg genkey)"
		echo "S1 = 20"
		echo "S2 = 30"
		echo "S3 = 20"
		echo "S4 = 20"
		echo "H1 = 1000-2000"
		echo "H2 = 3000-4000"
		echo "H3 = 5000-6000"
		echo "H4 = 7000-8000"
		echo "HeaderProtectionKey = $(awg genpsk)"
		echo "ContentPaddingAddition = 10-40"
		echo "RandomTrailers = on"
		echo "DisableCookies = on"
	} >"$probe"
	ip link del "$iface" 2>/dev/null || true
	probe_iface_create "$iface" || return 1
	awg setconf "$iface" "$probe" >/dev/null 2>&1 || rc=1
	ip link del "$iface" 2>/dev/null || true
	return $rc
}

check_versions() {
	local tv
	tv=$(tools_version)
	[ -n "$tv" ] || die "awg не отвечает на --version — tools не поставились"
	version_ge "$tv" "$awg_version" ||
		die "amneziawg-tools $tv, а нужно >= $awg_version (--from-source или AWG_VERSION=)"
	if $userspace; then
		command -v amneziawg-go >/dev/null || die "нет amneziawg-go"
		[ -c /dev/net/tun ] || die "нет /dev/net/tun — userspace-реализации не на чем работать"
		backend_speaks_awg31 ||
			die "amneziawg-go не понимает параметры $awg_version"
		ok "tools $tv, amneziawg-go понимает $awg_version"
		return 0
	fi
	modprobe amneziawg 2>/dev/null || true
	if [ ! -e /sys/module/amneziawg ]; then
		if command -v mokutil >/dev/null && mokutil --sb-state 2>/dev/null | grep -qi enabled; then
			die "модуль amneziawg не грузится, и включён Secure Boot — dkms-модуль надо подписать (mokutil --import) либо выключить SB"
		fi
		die "модуль amneziawg не загрузился: dkms status; journalctl -k | tail"
	fi
	backend_speaks_awg31 ||
		die "модуль ядра не понимает параметры $awg_version — в нём поколение старше (--from-source)"
	ok "tools $tv, модуль понимает $awg_version (пакетная версия модуля $(kmod_pkg_version) — это не поколение)"
}

versions_ok() {
	local tv
	tv=$(tools_version)
	[ -n "$tv" ] && version_ge "$tv" "$awg_version" || return 1
	if $userspace; then
		command -v amneziawg-go >/dev/null || return 1
	else
		modprobe amneziawg 2>/dev/null || true
		[ -e /sys/module/amneziawg ] || return 1
	fi
	backend_speaks_awg31
}

# ============================================================================
#  Модуль после обновления ядра
# ============================================================================
# Штатный /etc/kernel/postinst.d/dkms пересобирает модуль сам, когда ставится
# новое ядро, — но только если к тому моменту лежат его заголовки, и молча
# проглатывает неудачу. Этот юнит закрывает остаток: на каждой загрузке
# добирает несобранное и, главное, ГРОМКО падает, если модуля нет. Без него
# отвалившийся после ребута vpn обнаруживается попыткой подключиться.
install_ensure_module() {
	cat >/usr/local/sbin/amwg-ensure-module <<'ENSURE'
#!/bin/bash
# Собрать (если надо) и загрузить ядерный модуль amneziawg. Зовётся юнитом
# amwg-ensure-module.service до подъёма интерфейса; пишет в journal.
set -euo pipefail

command -v dkms >/dev/null 2>&1 || { echo "dkms не установлен — пропускаю"; exit 0; }

# Цели — ВСЕ ядра с каталогом build, а не uname -r: сразу после обновления ядра
# работает ещё старое, а заголовки нового уже на диске, и собирать надо под него.
targets=()
for build in /lib/modules/*/build; do
	[ -d "$build" ] || [ -L "$build" ] || continue
	targets+=("$(basename "$(dirname "$build")")")
done
if [ ${#targets[@]} -eq 0 ]; then
	echo "нет заголовков ядра — собирать не подо что (apt install linux-headers-\$(uname -r))" >&2
	exit 1
fi

for kver in "${targets[@]}"; do
	if dkms status -m amneziawg -k "$kver" 2>/dev/null | grep -q installed; then
		continue
	fi
	echo "собираю amneziawg под $kver"
	dkms autoinstall -k "$kver" || echo "сборка под $kver не прошла" >&2
done
depmod -a 2>/dev/null || true

if ! modprobe amneziawg 2>&1; then
	echo "модуль не грузится под текущее ядро $(uname -r)" >&2
	echo "смотреть: dkms status; /var/lib/dkms/amneziawg/*/$(uname -r)/log/make.log" >&2
	exit 1
fi
lsmod | grep -q '^amneziawg ' || { echo "modprobe прошёл, а модуля в lsmod нет" >&2; exit 1; }
echo "amneziawg $(modinfo -F version amneziawg) загружен под $(uname -r)"
ENSURE
	chmod 0755 /usr/local/sbin/amwg-ensure-module

	# Before= задаёт только ПОРЯДОК, а не зависимость: если сборка не удалась,
	# awg-quick всё равно стартует и ругнётся сам. Так понятнее при разборе, чем
	# висящий в очереди юнит.
	cat >/etc/systemd/system/amwg-ensure-module.service <<UNIT
[Unit]
Description=amwg: собрать и загрузить модуль amneziawg до подъёма интерфейса
After=systemd-modules-load.service local-fs.target
Before=awg-quick@$iface.service
ConditionPathExists=/usr/local/sbin/amwg-ensure-module

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/amwg-ensure-module
TimeoutStartSec=600

[Install]
WantedBy=multi-user.target
UNIT
	chmod 0644 /etc/systemd/system/amwg-ensure-module.service
	systemctl daemon-reload
	systemctl enable amwg-ensure-module.service >/dev/null 2>&1 ||
		warn "amwg-ensure-module.service не включился"
	systemctl start amwg-ensure-module.service ||
		warn "amwg-ensure-module отработал с ошибкой: systemctl status amwg-ensure-module"
	ok "модуль переживёт обновление ядра: amwg-ensure-module.service"
}

# Штатный awg-quick@ — Type=oneshot без Restart=, так что упавший на загрузке
# интерфейс остаётся лежать до ручного вмешательства. А причины бывают
# переходящие: модуль досбирался позже, чем стартовал юнит, или внешнего
# интерфейса ещё не было и правило MASQUERADE в PostUp не применилось.
#
# Restart=on-failure для oneshot systemd разрешает (запрещены только always и
# on-success). Попытки ограничены сознательно: пять раз по 30 секунд, дальше
# юнит остаётся в failed — вечно мигающий сервис хуже честной ошибки.
install_restart_dropin() {
	local dir="/etc/systemd/system/awg-quick@$iface.service.d"
	install -d -m 0755 "$dir"
	{
		echo "# Положил niko-amwg install.sh"
		echo "[Unit]"
		echo "StartLimitIntervalSec=10min"
		echo "StartLimitBurst=5"
		echo
		echo "[Service]"
		echo "Restart=on-failure"
		echo "RestartSec=30s"
		if $userspace; then
			# так awg-quick поднимает интерфейс go-реализацией вместо ядра
			echo "Environment=WG_QUICK_USERSPACE_IMPLEMENTATION=amneziawg-go"
		fi
	} >"$dir/10-amwg.conf"
	chmod 0644 "$dir/10-amwg.conf"
	systemctl daemon-reload
	ok "интерфейс переподнимется сам: Restart=on-failure, пять попыток"
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

# Фаервол не трогаем принципиально: установщик ставит vpn, а решать, кому машина
# видна снаружи, — не его дело. Но сказать, ЧТО именно тут стоит и какой командой
# открыть порт, дешево и полезно.
firewall_kind() {
	if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "^Status: active"; then
		echo ufw
	elif command -v firewall-cmd >/dev/null 2>&1 && [ "$(firewall-cmd --state 2>/dev/null)" = running ]; then
		echo firewalld
	elif command -v nft >/dev/null 2>&1 && nft list ruleset 2>/dev/null | grep -q 'hook input'; then
		echo nftables
	elif command -v iptables >/dev/null 2>&1 &&
		iptables -S INPUT 2>/dev/null | grep -qE '^-P INPUT DROP|^-A INPUT'; then
		echo iptables
	else
		echo none
	fi
}

firewall_hint() {
	case "$(firewall_kind)" in
	ufw)
		echo "  фаервол       обнаружен активный ufw, порт я НЕ открывал:"
		echo "                   ufw allow $port/udp" ;;
	firewalld)
		echo "  фаервол       обнаружен firewalld, порт я НЕ открывал:"
		echo "                   firewall-cmd --permanent --add-port=$port/udp && firewall-cmd --reload" ;;
	nftables)
		echo "  фаервол       обнаружены правила nftables, порт я НЕ открывал:"
		echo "                   nft add rule inet filter input udp dport $port accept"
		echo "                   (подставь свои имена таблицы и цепочки; сохранить —"
		echo "                    nft list ruleset > /etc/nftables.conf)" ;;
	iptables)
		echo "  фаервол       в INPUT есть свои правила, порт я НЕ открывал:"
		echo "                   iptables -I INPUT -p udp --dport $port -j ACCEPT"
		echo "                   (сохранить: netfilter-persistent save)" ;;
	*)
		echo "  фаервол       локального фильтра не нашёл — на самой машине порт открыт" ;;
	esac
	echo "                если сервер в облаке, порт $port/udp нужно открыть ещё и в"
	echo "                security group провайдера — туда я не хожу тем более"
}

# --endpoint можно задать и с портом (host:443), и без. Разбираем так: порт
# внутри endpoint выигрывает, но если рядом стоит явный --port с ДРУГИМ значением
# — это ошибка, а не повод угадывать, что человек имел в виду. Голый ipv6 берётся
# в скобки: иначе порт к нему не прилепить.
normalize_endpoint() {
	local ep=$1 host port_in=""
	case "$ep" in
	"["*"]:"*) port_in=${ep##*]:}; host="${ep%]:*}]" ;;
	"["*"]") host=$ep ;;
	*:*:*) host="[$ep]" ;;
	*:*) port_in=${ep##*:}; host=${ep%:*} ;;
	*) host=$ep ;;
	esac
	case "$port_in" in '' | *[!0-9]*) port_in="" ;; esac
	if [ -n "$port_in" ]; then
		if $port_explicit && [ "$port_in" != "$port" ]; then
			die "порт задан дважды и по-разному: в --endpoint ($port_in) и в --port ($port)"
		fi
		port=$port_in
	fi
	endpoint=$host
}

detect_wan() {
	ip -4 route show default 2>/dev/null |
		awk '{for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit }}'
}

# Единственное, что стоит спросить: домен вместо ip даёт переезд между серверами
# без перевыпуска конфигов. Спрашиваем ЧЕРЕЗ /dev/tty: при `curl | bash` на stdin
# висит сам скрипт, и обычный read сожрал бы его остаток.
ask_endpoint() {
	local guess=$1 answer=""
	$ask_input || { echo "$guess"; return; }
	# именно проба /dev/tty, а не [ -t 1 ]: функция зовётся из $(...), и там
	# stdout — пайп, так что тест на терминал всегда врал бы «консоли нет»
	{ : >/dev/tty; } 2>/dev/null || { echo "$guess"; return; }
	{
		printf '\n%sАдрес, по которому клиенты будут приходить.%s\n' "$c_cyan" "$c_off"
		printf 'Домен удобнее ip: сменишь сервер — переставишь A-запись, и старые\n'
		printf 'конфиги останутся рабочими. Ip не светится в dns-запросе клиента.\n'
		printf 'Домен или ip [%s]: ' "$guess"
	} >/dev/tty
	read -r answer </dev/tty || answer=""
	answer=$(echo "$answer" | tr -d '[:space:]')
	echo "${answer:-$guess}"
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
		echo "# AmneziaWG $awg_version, сгенерирован $SELF $(date -Is)"
		echo "# Секции [Peer] ниже пишет amwg — правки в них перетрутся."
		echo "# Параметры обфускации обязаны совпадать с клиентом; их копирует"
		echo "# в клиентские конфиги amwg, руками ничего сверять не надо."
		echo "# PostUp/PostDown — обвязка САМОГО туннеля (nat и форвардинг), она"
		echo "# живёт и умирает вместе с интерфейсом. Входящий порт тут сознательно"
		echo "# не открывается: это политика доступа к машине, а не дело установщика."
		echo "[Interface]"
		echo "PrivateKey = $priv"
		echo "Address = $server_ip/$prefix"
		echo "ListenPort = $port"
		echo "PostUp = iptables -t nat -I POSTROUTING 1 -s $subnet -o $wan -j MASQUERADE; iptables -I FORWARD 1 -i %i -j ACCEPT; iptables -I FORWARD 1 -o %i -j ACCEPT"
		echo "PostDown = iptables -t nat -D POSTROUTING -s $subnet -o $wan -j MASQUERADE; iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT"
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
  реализация    $(if $userspace; then echo "amneziawg-go (userspace)"; else echo "ядерный модуль"; fi)
  конфиг        $conf
  клиенты       $CONF_DIR/amwg/state.json (ключи, 0600)
  трафик        $CONF_DIR/amwg/traffic.json, копит amwg-poll.timer

$(firewall_hint)

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

	step "AmneziaWG $awg_version"
	if $from_source; then
		install_from_source
	elif $from_repo; then
		install_from_repo_debs "$(pick_series)"
	else
		add_repo "$(pick_series)"
		install_from_repo || warn "apt поругался, проверяю что вышло"
	fi
	# go-реализация ставится ДО проверок: без неё проверять поколение нечем
	if $userspace && ! command -v amneziawg-go >/dev/null 2>&1; then
		install_userspace_go
	fi
	if ! $from_source && ! versions_ok; then
		warn "в репозитории версия старше $awg_version — собираю из исходников"
		warn "не пойдёт и сборка — есть --from-repo: пакеты из niko-amwg/debs"
		install_from_source
	fi
	if $hold && ! $from_source; then
		apt-mark hold amneziawg amneziawg-dkms amneziawg-tools >/dev/null 2>&1 &&
			info "версии зафиксированы (apt-mark unhold — снять)"
	fi
	check_versions
	if $userspace; then
		info "ensure-module не нужен: пересобирать под новое ядро нечего"
	else
		install_ensure_module
	fi

	step "хост"
	setup_sysctl
	[ -n "$wan" ] || wan=$(detect_wan)
	[ -n "$wan" ] || die "не понял внешний интерфейс — задай --wan"
	if [ -z "$endpoint" ]; then
		endpoint=$(ask_endpoint "$(detect_endpoint)")
	fi
	[ -n "$endpoint" ] || die "не понял внешний адрес — задай --endpoint"
	normalize_endpoint "$endpoint"
	ok "внешний интерфейс $wan, клиенты придут на $endpoint:$port"

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
	local created="" fresh=false
	if [ ! -f "$CONF_DIR/amwg/state.json" ]; then
		fresh=true
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
	install_restart_dropin
	systemctl restart "awg-quick@$iface" ||
		die "интерфейс не поднялся: journalctl -u awg-quick@$iface -n 40"
	awg show "$iface" >/dev/null || die "awg show $iface пустой"
	ok "интерфейс $iface поднят, автозапуск включён"
	amwg apply >/dev/null

	# только на свежей установке: повторный запуск (обновить пакеты, поменять
	# endpoint) не должен молча заводить ещё одного клиента
	if $fresh && [ -n "$first_client" ] &&
		! amwg list --json | grep -q "\"name\": \"$first_client\""; then
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
