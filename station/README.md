# Estação ADS-B (Le Potato + RTL-SDR)

Uma estação própria de rastreio de aviões para o canto do céu do Quad Board. Ela vê os aviões que passam sobre Salvador, onde as redes públicas (adsb.lol, adsb.fi) quase não têm receptores.

- **Placa:** Libre Computer **Le Potato** (AML-S905X-CC), com rede cabeada
- **Rádio:** **RTL-SDR Blog V4** (serve qualquer RTL-SDR) e uma antena de 1090 MHz
- **Software:** Debian 12 oficial da Libre Computer, mais o driver do RTL-SDR Blog (com suporte ao V4), o [readsb](https://github.com/wiedehopf/readsb) e, opcional, o mapa [tar1090](https://github.com/wiedehopf/tar1090)

```
antena ─ RTL-SDR V4 ─ Le Potato (readsb) ── http://<estação>/data/aircraft.json
                                                   ▲
                       servidor do Quad Board ─────┘  junta com adsb.lol / adsb.fi
                                                       e desenha o canto do céu
```

O servidor busca os dados na estação; a estação não precisa saber do servidor.

## 1. Gerar a imagem

Num Linux (ou WSL2, ou no próprio CasaOS), como root:

```sh
sudo apt install btrfs-progs mtools xz-utils fdisk git curl
sudo station/build-image.sh            # saída em station/work/out/
```

O script não monta nada nem roda código arm64: ele baixa a imagem oficial (e confere o SHA-256), lê a partição btrfs, acrescenta os arquivos da estação e reescreve a partição com o mesmo UUID. Também põe dentro da imagem os pacotes `.deb` que faltam e o código-fonte do driver e do readsb, nos commits fixados em [`sources.lock`](sources.lock). Assim, o primeiro boot funciona sem internet.

Variável opcional: `ROOT_MB` define o tamanho da partição na imagem (padrão: 3072). No primeiro boot, ela cresce até ocupar o cartão inteiro.

## 2. Gravar e configurar

1. Grave o `adsb-station-lepotato-AAAAMMDD.img.xz` num cartão de 8 GB ou mais, com o [balenaEtcher](https://etcher.balena.io) ou o Raspberry Pi Imager ("usar imagem personalizada").
2. Tire e recoloque o cartão no computador. Na partição **boot** (FAT, abre no Windows), edite o `adsb-station.conf`:
   - `PASSWORD` e/ou `SSH_PUBKEY`: sem pelo menos um dos dois, a estação se recusa a configurar;
   - `LAT`, `LON` e `ALT_M` da antena;
   - `HOSTNAME`, se quiser outro nome além de `adsb-station`.
3. Ligue o cabo de rede, o RTL-SDR e a fonte (5 V, 2 A ou mais).

## 3. Primeiro boot

A estação instala os pacotes, compila o driver e o readsb e reinicia. Leva uns 10 a 15 minutos. Com HDMI, dá para acompanhar o progresso na tela.

O log fica em `/var/log/adsb-firstboot.log` e também no próprio cartão, na partição boot (`adsb-firstboot.log`). Se algo falhar, dá para ler o log no PC, corrigir o `.conf` e religar. Ao terminar, a estação:

- apaga a senha do `adsb-station.conf`;
- cria o `adsb-firstboot.done`. Para refazer a configuração, apague esse arquivo e religue a placa;
- bloqueia o login do root (use o seu usuário com `sudo`).

Depois do reboot:

```sh
ssh adsb@adsb-station.local
systemctl status readsb
viewadsb                                   # tabela ao vivo no terminal (Ctrl+C sai)
curl -s localhost/data/aircraft.json | jq '.aircraft | length'
```

No navegador: `http://adsb-station.local/` tem os links, e `http://adsb-station.local/tar1090/` mostra o mapa, se houve internet no primeiro boot.

Os ajustes do rádio (ganho, bias-tee, posição) ficam em `/etc/default/readsb`. Depois de editar, rode `sudo systemctl restart readsb`.

## 4. Ligar no servidor

No dashboard do Quad Board (`http://<servidor>:8740/?k=<QUAD_ADMIN>`), no card **Sky**:

- **Sky corner shows:** `Planes overhead (ADS-B)`
- **Your ADS-B station:** `http://<IP da estação>/data/aircraft.json`
- **Also merge the public networks:** deixe marcado para somar adsb.lol e adsb.fi

Use o **IP**, não `adsb-station.local`: o container do servidor normalmente não resolve nomes `.local`. Reserve o IP da estação no roteador (reserva de DHCP).

Outra opção é definir `QUAD_ADSB_LOCAL=http://<IP>/data/aircraft.json` no `.env` do servidor. Isso vale como padrão até alguém mudar o campo no dashboard.

A tabela **Health** do dashboard mostra, em "Plane networks", quantos aviões cada fonte vê dentro do raio (`station: 7 · adsb.lol: 2 ...`), ou o erro, se a estação não responder.

## Notas

- **RTL-SDR Blog V4:** o `librtlsdr` 0.6 do Debian não reconhece o V4. Por isso, o driver vem do [rtl-sdr-blog](https://github.com/rtlsdrblog/rtl-sdr-blog), instalado em `/usr/local`, e o driver DVB-T do kernel fica bloqueado (`/etc/modprobe.d/blacklist-rtl-sdr.conf`).
- **Bias-tee:** `BIAS_TEE=yes` alimenta um LNA ou filtro pelo cabo. Não ligue com uma antena em curto DC.
- **Portas** (para alimentar outras redes depois): Beast na 30005, SBS na 30003 e entrada Beast nas 30004/30104.
- **Atualizar o readsb ou o driver:** troque o commit no `sources.lock` e gere uma imagem nova. Na estação já em uso, compile à mão a partir do repositório.
