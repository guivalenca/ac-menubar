#!/bin/zsh
# Busca o token e a chave do seu ar-condicionado na SUA conta SmartHome (MSmartHome) e grava em
# ~/.config/ac-menubar/config.json. Dê dois cliques no Finder ou rode no Terminal.
# A senha não é exibida, registrada nem gravada; o token e a chave não são exibidos.
set -u

DIR=${0:A:h}
UVX="$HOME/.local/bin/uvx"
[[ -x "$UVX" ]] || UVX=$(command -v uvx || true)

# Keeps the window open after a double-click so the result can be read.
finish() {
  if [[ -t 0 ]]; then
    echo
    read -s -k 1 "?Pressione qualquer tecla para fechar."
    echo
  fi
  exit $1
}

if [[ -z "$UVX" ]]; then
  echo "Este script precisa do uv. Instale com:"
  echo "  curl -LsSf https://astral.sh/uv/install.sh | sh"
  finish 1
fi

echo "Use a conta do app SmartHome (MSmartHome) em que o ar-condicionado está cadastrado."
read "AC_EMAIL?E-mail da conta SmartHome: "
read -s "AC_PASS?Senha (não aparece enquanto você digita): "
echo
export AC_EMAIL AC_PASS

"$UVX" --from msmart-ng==2026.9.0 python -I "$DIR/get_token.py"
rc=$?
unset AC_EMAIL AC_PASS
finish $rc
