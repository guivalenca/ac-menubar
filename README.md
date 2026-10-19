<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="Resources/Brand/png/wordmark-dark@2x.png">
    <img src="Resources/Brand/png/wordmark@2x.png" width="420" alt="GuiCondicionado">
  </picture>
</p>

GuiCondicionado é um app de barra de menus para macOS que controla um ar-condicionado Midea pela rede
local. Ele fala direto com o aparelho pelo protocolo LAN V3 da Midea, sem depender da nuvem no uso do
dia a dia. A conta SmartHome entra só uma vez, para obter o token e a chave do aparelho.

## Recursos

- Liga e desliga, temperatura alvo de 16 a 30 °C, modo (Refrigerar, Desumidificar, Ventilar,
  Automático), ventilação, direção do ar, Eco, Turbo e Dormir.
- Temperatura interna e externa no painel; ícone e temperatura na barra de menus.
- Alterações aplicadas na hora e enviadas ao aparelho logo em seguida. Falhas aparecem no rodapé,
  sem janelas nem alertas.
- O item só aparece na barra de menus quando o Mac está na mesma rede do aparelho, ou quando há algo
  a resolver, como a permissão de Rede Local.
- Bipe do aparelho opcional, interface em português e sem ícone no Dock.

## Requisitos

- macOS 15 ou mais recente.
- Toolchain Swift 6 (Xcode 16 ou as Command Line Tools equivalentes).
- Um ar-condicionado Midea com protocolo V3 na rede local, cadastrado no app SmartHome (MSmartHome).
- [uv](https://docs.astral.sh/uv/), para o script que busca o token.

## Compilar e instalar

```sh
scripts/build-app.sh --install
```

O script compila em modo release, monta e assina (ad hoc) o `GuiCondicionado.app`, copia para
`~/Applications` e abre o app. Sem `--install`, só gera o app e mostra o caminho.

Os arquivos de build ficam em `~/Library/Caches/guicondicionado-build`, fora do repositório. Se o
projeto estiver na Mesa sincronizada pelo iCloud, um `.build` dentro dele quebraria a assinatura (o
iCloud adiciona metadados do Finder aos arquivos) e faria o iCloud sincronizar centenas de MB. Pelo
mesmo motivo, use um `--scratch-path` fora do repositório ao rodar `swift build` ou `swift test`:

```sh
swift test --scratch-path ~/Library/Caches/guicondicionado-build
```

## Obter o token e a chave

Aparelhos V3 só aceitam comandos depois de uma autenticação com um token e uma chave que a nuvem da
Midea fornece. Para buscá-los com a sua própria conta SmartHome:

1. Conecte o Mac à mesma rede do ar-condicionado.
2. Dê dois cliques em `tools/get-token.command` (ou rode o arquivo no Terminal).
3. Informe o e-mail e a senha da conta SmartHome em que o aparelho está cadastrado.
4. Escolha o aparelho na lista e o nome do cômodo.

O script usa o [msmart-ng](https://github.com/mill1000/midea-msmart) 2026.9.0 pelo `uvx`. Ele procura
os aparelhos na rede, pede o token e a chave à nuvem, testa cada opção no próprio aparelho (quando ele
responde) e grava a que funcionar. A senha não é exibida nem gravada, e o token e a chave não aparecem
na tela.

Se a busca não encontrar o aparelho, o script pede o ID e o IP. Também dá para informá-los antes:
`AC_DEVICE_ID=<id> AC_HOST=<ip> tools/get-token.command`.

## Configuração

O app e o `actool` leem `~/.config/ac-menubar/config.json`. O script de token cria ou atualiza o
arquivo, e o app só altera o IP do aparelho quando ele muda. As permissões são só do seu usuário (pasta
`0700`, arquivo `0600`):

```json
{
  "homeRouterMACs": [],
  "devices": [
    { "id": 18838586676582, "name": "Sala", "host": "192.0.2.50", "port": 6444,
      "token": "<hex>", "key": "<hex>" }
  ]
}
```

O arquivo fica fora do repositório e nunca deve ser versionado. O `.gitignore` também ignora
`config.json` e arquivos de captura (`*.capture.json`, `capture*.json`, `sala*.json`,
`*candidates*.json`), para o caso de alguém salvar uma cópia dentro do projeto.

## Permissão de Rede Local

Na primeira conexão, o macOS pergunta se o GuiCondicionado pode encontrar e se conectar a
dispositivos na rede local. Permita. Se a permissão for negada, o app explica o bloqueio no painel;
para liberar, ative o GuiCondicionado em Ajustes do Sistema → Privacidade e Segurança → Rede Local.
Ao usar o `actool` ou o script de token, a permissão vale para o app de terminal.

Com o firewall do macOS ativo, as respostas da busca de aparelhos chegam como conexões de entrada. Se
o macOS perguntar, permita; se a busca não encontrar nada, confira o app (ou o `actool`) em Ajustes do
Sistema → Rede → Firewall → Opções.

## CLI de desenvolvimento

O `actool` usa a mesma biblioteca do app e lê o mesmo arquivo de configuração:

```sh
SCRATCH=~/Library/Caches/guicondicionado-build
swift build --scratch-path $SCRATCH --product actool
alias actool="$(swift build --scratch-path $SCRATCH --show-bin-path)/actool"

actool discover
actool status [nome]
actool on|off [nome]
actool set [nome] temp=22 mode=cool fan=auto swing=off eco=on turbo=off sleep=off beep=on
```

`[nome]` é o `name` do aparelho na configuração; sem ele, vale o primeiro. Com `MIDEA_DEBUG=1`, a
descoberta mostra os envios e respostas.

## Estrutura do projeto

| Caminho | Conteúdo |
|---|---|
| `Sources/MideaKit` | Protocolo Midea V3 em Swift, portado do msmart-ng: descoberta, criptografia, pacotes, sessão TCP e configuração |
| `Sources/GuiCondicionado` | App SwiftUI da barra de menus |
| `Sources/actool` | CLI de desenvolvimento |
| `Tests/MideaKitTests` | Testes; `Vectors.json` traz vetores gerados pelo msmart-ng |
| `tools/gen_vectors.py` | Gera `Vectors.json` a partir de dados fixos e sintéticos, sem precisar de um aparelho |
| `tools/get-token.command`, `tools/get_token.py` | Busca o token e a chave e grava a configuração |
| `tools/make_icon.swift` | Gera o ícone e a marca em `Resources/Brand` |
| `scripts/build-app.sh` | Compila, assina e instala o app |
| `DESIGN.md` | Guia de design: componentes, estados, textos, comportamento na barra de menus e regras de desempenho |

Para regenerar os vetores de teste:

```sh
uvx --from msmart-ng==2026.9.0 python -I tools/gen_vectors.py > Tests/MideaKitTests/Vectors.json
```

Antes de mudar a interface, leia o [DESIGN.md](DESIGN.md). A seção 9 explica como adicionar aparelhos
e controles e como conferir o resultado com snapshots (`GuiCondicionado --snapshot out.png`), sem
aparelho nem rede.

## Créditos

O protocolo em `MideaKit` e os vetores de teste vêm do
[msmart-ng](https://github.com/mill1000/midea-msmart), de mill1000, distribuído sob a licença MIT.
