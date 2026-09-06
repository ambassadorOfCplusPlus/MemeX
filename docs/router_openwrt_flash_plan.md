# Прошивка роутера OpenWRT + мост — готовый план (6 сентября 2026)

Собрано агентом-исследователем. Прошить удалённо НЕЛЬЗЯ (нужны физические шаги), но здесь всё
готовое: образы, проверенные контрольные суммы, конфиг моста. Делать, когда будет доступ руками.

## Инвентарь сети
- Главный роутер: ASUS TUF-AX4200, 192.168.50.1. SSID **arslanbek**: 2.4 ГГц, **канал 12**,
  802.11ax, WPA2/CCMP, пароль **15052006**.
- Устройство X: **ASUS RT-N11P B1** (MediaTek MT7628, 8 МБ флеш / 32 МБ ОЗУ), 192.168.1.1,
  admin/admin. Профиль OpenWRT — `asus_rt-n12-vp-b1`. **СЕЙЧАС ЗАВИС** (httpd заморожен от
  перегрева — отвалившийся радиатор; ARP есть, порты 80/443 открыты, но HTTP молчит).
- Устройство Y: TP-Link RE-репитер, 192.168.50.159. Точная модель/ревизия неизвестна (нужен
  пароль или наклейка). НЕ прошивать, пока не известна точная ревизия.

## A. Сначала оживить RT-N11P
Физически выключить-включить. **Перед всем — посадить радиатор на термопрокладку/пасту**, иначе
будет виснуть снова, а зависание посреди прошивки = кирпич.

## B. Безопасный вариант (рекомендуется пока): оставить репитером
После загрузки зайти на http://192.168.1.1 (admin/admin), убедиться что режим Репитер к
arslanbek/15052006 жив, и **поставить канал Wi-Fi = 12** (как у TUF, меньше помех). TX-мощность
НЕ поднимать (больше тепла → зависания).

## C. Прошить OpenWRT (только после ремонта радиатора, руками)
Образы OpenWRT 24.10.0, профиль `asus_rt-n12-vp-b1`, проверенные sha256:
- initramfs (для TFTP): `openwrt-24.10.0-ramips-mt76x8-asus_rt-n12-vp-b1-initramfs-kernel.bin`
  sha256 `66cfa8df771a982b01c4cfb254298fc984e480b3c1da3a57966fde8665539d66`
- sysupgrade: `openwrt-24.10.0-ramips-mt76x8-asus_rt-n12-vp-b1-squashfs-sysupgrade.bin`
  sha256 `1e57b5951bc0e9981a2659782f0d84d2dd608e637a117fd5dcef740a5302c6eb`
- Проверка: `powershell "(Get-FileHash -Algorithm SHA256 '<файл>').Hash"`

TFTP-recovery: ПК на **192.168.1.75/24**, кабель в LAN-порт, выключить роутер, **зажать Reset и
включить** — держать пока не замигает индикатор питания, затем TFTP-PUT **initramfs**-образа на
**192.168.1.1** (имя любое). После перезагрузки → LuCI на http://192.168.1.1. Оттуда прошить
**sysupgrade** (System → Backup/Flash Firmware) для постоянной установки.

## D. Мост после прошивки (relayd): интернет в кабель, без раздачи Wi-Fi
arslanbek = 2.4 ГГц, RT-N11P тоже 2.4 — диапазон совпадает.
```
opkg update && opkg install luci-proto-relay relayd luci-app-relay
uci set network.lan.ipaddr='192.168.50.2'    # подтвердить, что вне DHCP-пула TUF, иначе взять свободный
uci set network.lan.netmask='255.255.255.0'
uci set network.lan.gateway='192.168.50.1'
uci set network.lan.dns='192.168.50.1'
uci set network.wwan=interface; uci set network.wwan.proto='dhcp'
uci set wireless.@wifi-iface[0].mode='sta'
uci set wireless.@wifi-iface[0].ssid='arslanbek'
uci set wireless.@wifi-iface[0].encryption='psk2'
uci set wireless.@wifi-iface[0].key='15052006'
uci set wireless.@wifi-iface[0].network='wwan'
uci set wireless.radio0.disabled='0'
uci set network.stabridge=interface; uci set network.stabridge.proto='relay'
uci set network.stabridge.network='lan wwan'
uci commit && reload_config && wifi reload
```

## E. TP-Link (устройство Y)
Прочитать точную модель + `Ver:` с наклейки или в веб-панели (System Tools → System Info) прежде
чем вообще планировать прошивку.

Источник: OpenWRT downloads sha256sums (ramips/mt76x8 24.10.0); OpenWRT devel-патч RT-N11P B1.
