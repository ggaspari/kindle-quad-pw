# Servidor no CasaOS

O servidor roda num container Docker no CasaOS. Configurações, estado e cache ficam em `/DATA/AppData/quadboard/`, a pasta de dados de apps do CasaOS. Por isso, sobrevivem a reinícios e atualizações.

## Instalar

Entre no CasaOS por SSH, com o mesmo usuário da instalação:

```sh
ssh <usuario>@casaos.local
```

Baixe o projeto, crie o `.env` e suba o container:

```sh
sudo mkdir -p /DATA/AppData/quadboard && cd /DATA/AppData/quadboard
sudo git clone https://github.com/ggaspari/kindle-quad-pw.git src
cd src
sudo cp .env.example .env
sudo nano .env            # troque QUAD_TOKEN e QUAD_ADMIN
sudo docker compose up -d --build
```

O primeiro build leva alguns minutos. Para confirmar que subiu:

```sh
sudo docker ps --filter name=quadboard     # STATUS deve chegar em "(healthy)"
sudo docker logs -f quadboard              # Ctrl+C para sair
```

Se o CasaOS não tiver `git`, baixe o código com
`curl -L https://github.com/ggaspari/kindle-quad-pw/archive/refs/heads/main.tar.gz | sudo tar xz && sudo mv kindle-quad-pw-main src`.
Se o repositório for privado, o `git clone` vai pedir login: use um token do GitHub como senha.

## Dashboard

No computador ou no celular, abra:

```
http://casaos.local:8740/?k=<QUAD_ADMIN>
```

A localização padrão já é Salvador. O card **Kindle Paperwhite** mostra a prévia do que vai aparecer no Kindle.

## Apontar o Kindle para o servidor

No `quad.conf` do Kindle, use o **IP** do CasaOS, não `casaos.local`. O Kindle provavelmente não resolve nomes `.local` (mDNS).

```sh
hostname -I     # no CasaOS: o primeiro endereço, por exemplo 192.168.1.50
```

```
SERVER=http://192.168.1.50:8740
TOKEN=<o mesmo QUAD_TOKEN do .env>
```

Reserve esse IP para o CasaOS no roteador (reserva de DHCP), para que ele não mude.

## Atualizar

```sh
cd /DATA/AppData/quadboard/src
sudo git pull
sudo docker compose up -d --build
```

Depois de uma atualização que mude dependências do servidor (por exemplo, o `sgp4` das passagens da ISS), o `--build` acima é o que instala a dependência nova.

## Observações

- O resumo de uma linha escrito pelo Claude precisa do `claude` CLI, que não existe dentro do container. Por isso ele vem desligado: a faixa de cima mostra o próximo jogo ou a manchete principal.
- A porta é a 8740. Se ela já estiver em uso no CasaOS, troque o lado esquerdo em `docker-compose.yml` (por exemplo `"8750:8740"`) e ajuste o `SERVER` do Kindle.
- O container é criado pelo `docker compose` na linha de comando. Por isso o CasaOS pode listá-lo como app externo em vez de app da loja. Ele reinicia sozinho com o servidor (`restart: unless-stopped`).
- A imagem é Python 3.12 slim e funciona em amd64 e arm64 (Raspberry Pi, ZimaBoard etc.).
