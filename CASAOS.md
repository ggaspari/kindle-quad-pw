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

## Resumo do Claude (opcional)

A faixa no topo do painel pode trazer uma frase escrita pelo Claude que resume o dia. O Claude Code já vem instalado na imagem; falta só autenticar com a sua assinatura Claude:

1. Num computador com navegador e o [Claude Code](https://code.claude.com) instalado, rode `claude setup-token`, faça o login e copie o token que ele imprime (começa com `sk-ant-oat01-`).
2. No CasaOS, cole no `.env`:
   ```
   CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-...
   ```
3. Recrie o container: `sudo docker compose up -d --build`.

Com o token presente, o resumo liga sozinho. Se você já tinha desmarcado a opção, marque de novo no dashboard: "Claude writes a one-line daily brief". A linha **Claude brief** da tabela Health mostra o último resumo ou o erro (por exemplo, um token inválido). O modelo padrão é `haiku` (o Haiku atual), e o idioma vem de "Brief language" (padrão: português).

O token dá acesso à sua conta: ele fica só no `.env`, que está fora do git. Não compartilhe esse arquivo.

## Atualizar

```sh
cd /DATA/AppData/quadboard/src
sudo git pull
sudo docker compose up -d --build
```

Depois de uma atualização que mude dependências do servidor (por exemplo, o `sgp4` das passagens da ISS), o `--build` acima é o que instala a dependência nova.

## Observações

- Sem `CLAUDE_CODE_OAUTH_TOKEN`, o resumo do Claude fica desligado: a faixa de cima mostra o próximo jogo ou a manchete principal.
- A porta é a 8740. Se ela já estiver em uso no CasaOS, troque o lado esquerdo em `docker-compose.yml` (por exemplo `"8750:8740"`) e ajuste o `SERVER` do Kindle.
- O container é criado pelo `docker compose` na linha de comando. Por isso o CasaOS pode listá-lo como app externo em vez de app da loja. Ele reinicia sozinho com o servidor (`restart: unless-stopped`).
- A imagem é Python 3.12 slim com Node.js e Claude Code, e funciona em amd64 e arm64 (Raspberry Pi, ZimaBoard etc.). O Claude Code não se atualiza sozinho dentro do container (`DISABLE_AUTOUPDATER=1`); um `--build` traz a versão nova.
