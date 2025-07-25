#!/bin/bash

# Script de Configuración para un Nodo Bitcoin Core v25.0

set -e

# Configuración
USER_HOME=$(eval echo ~${SUDO_USER:-$USER})
BITCOIN_DIR="$USER_HOME/.bitcoin"
BITCOIN_CONF="$BITCOIN_DIR/bitcoin.conf"
RPC_AUTH=""
NETWORK=""
SERVICE_FILE="/etc/systemd/system/bitcoind.service"
BITCOIN_VERSION="25.0"  # Se mantiene la versión 25.0
BITCOIN_TARBALL="bitcoin-${BITCOIN_VERSION}-x86_64-linux-gnu.tar.gz"
BITCOIN_URL="https://bitcoincore.org/bin/bitcoin-core-${BITCOIN_VERSION}/${BITCOIN_TARBALL}"
SHA256SUMS_URL="https://bitcoincore.org/bin/bitcoin-core-${BITCOIN_VERSION}/SHA256SUMS"
SHA256SUMS_ASC_URL="https://bitcoincore.org/bin/bitcoin-core-${BITCOIN_VERSION}/SHA256SUMS.asc"

# Verificar si el usuario es root
echo "[+] Verificando privilegios de root..."
if [[ $EUID -ne 0 ]]; then
  echo "[-] Este script debe ser ejecutado como root. Use sudo."
  exit 1
fi

# Actualizar e Instalar dependencias
echo "[+] Actualizando el sistema e instalando dependencias..."
apt update && apt upgrade -y
apt install -y wget tar gnupg

# Descargar el binario de Bitcoin Core y archivos relacionados
echo "[+] Descargando el binario de Bitcoin Core, sumas de comprobación y firmas..."
wget -q $BITCOIN_URL -O $BITCOIN_TARBALL
wget -q $SHA256SUMS_URL -O SHA256SUMS
wget -q $SHA256SUMS_ASC_URL -O SHA256SUMS.asc

if [[ ! -f $BITCOIN_TARBALL || ! -f SHA256SUMS || ! -f SHA256SUMS.asc ]]; then
  echo "[-] No se pudieron descargar los archivos necesarios. Saliendo."
  exit 1
fi

# Verificar la suma de comprobación SHA256
echo "[+] Verificando la suma de comprobación SHA256 del binario..."
sha256sum --ignore-missing --check SHA256SUMS
if [[ $? -ne 0 ]]; then
  echo "[-] La verificación de la suma de comprobación SHA256 falló. Saliendo."
  exit 1
fi
echo "[+] Suma de comprobación SHA256 verificada con éxito."

# Importar las claves de firma de Bitcoin Core
echo "[+] Verificando el directorio 'guix.sigs'..."
if [[ -d "guix.sigs" ]]; then
  echo "[!] El directorio 'guix.sigs' ya existe. Obteniendo los últimos cambios..."
  cd guix.sigs
  git pull --ff-only || { echo "[-] No se pudo actualizar 'guix.sigs'. Por favor, resuelva manualmente."; exit 1; }
  cd ..
else
  echo "[+] Clonando el repositorio 'guix.sigs'..."
  git clone https://github.com/bitcoin-core/guix.sigs guix.sigs || { echo "[-] No se pudo clonar 'guix.sigs'. Saliendo."; exit 1; }
fi

echo "[+] Importando las claves de firma de Bitcoin Core..."
gpg --import guix.sigs/builder-keys/* || { echo "[-] No se pudieron importar las claves de firma de Bitcoin Core. Saliendo."; exit 1; }

# Verificar la firma PGP del archivo SHA256SUMS
echo "[+] Verificando la firma PGP del archivo SHA256SUMS..."
gpg --verify SHA256SUMS.asc SHA256SUMS
if [[ $? -ne 0 ]]; then
  echo "[-] La verificación de la firma PGP falló. Saliendo."
  exit 1
fi
echo "[+] Firma PGP verificada con éxito."

# Extraer e instalar el binario de Bitcoin Core
echo "[+] Extrayendo el binario de Bitcoin Core..."
tar -xzf $BITCOIN_TARBALL
BITCOIN_EXTRACT_DIR="bitcoin-${BITCOIN_VERSION}"

if [[ -d "$BITCOIN_EXTRACT_DIR/bin" ]]; then
  sudo install -m 0755 -o root -g root -t /usr/local/bin $BITCOIN_EXTRACT_DIR/bin/*
  rm -rf $BITCOIN_TARBALL $BITCOIN_EXTRACT_DIR
  echo "[+] Los binarios de Bitcoin Core se instalaron con éxito."
else
  echo "[-] No se encontró la estructura de directorios esperada: $BITCOIN_EXTRACT_DIR/bin. Saliendo."
  rm -rf $BITCOIN_TARBALL $BITCOIN_EXTRACT_DIR
  exit 1
fi

# Volver al directorio de inicio del usuario
cd "$USER_HOME"

# Generar contraseña RPC
echo "[+] Generando contraseña RPC para que otros servicios se conecten a bitcoind..."
wget -q https://raw.githubusercontent.com/bitcoin/bitcoin/master/share/rpcauth/rpcauth.py -O rpcauth.py
if [[ ! -f rpcauth.py ]]; then
  echo "[-] No se pudo descargar el generador de contraseñas RPC. Saliendo."
  exit 1
fi

# Ejecutar el script de autenticación RPC
RPC_OUTPUT=$(python3 ./rpcauth.py bitcoinrpc)
RPC_AUTH=$(echo "$RPC_OUTPUT" | grep -oP '(?<=rpcauth=)\S+')
RPC_PASSWORD=$(echo "$RPC_OUTPUT" | awk '/Your password:/ {getline; print $1}' | tr -d '[:space:]')

# Mostrar la contraseña al usuario
echo "[+] La siguiente contraseña ha sido generada para su conexión RPC:"
echo "    Contraseña: $RPC_PASSWORD"
echo "[!] Por favor, guarde esta contraseña de forma segura, ya que no se mostrará de nuevo."

# Confirmar que el usuario guardó la contraseña
read -p "¿Ha guardado la contraseña? (si/no): " CONFIRM
if [[ "$CONFIRM" != "si" ]]; then
  echo "[-] Por favor, guarde la contraseña antes de continuar. Saliendo de la configuración."
  exit 1
fi

# Preguntar al usuario para elegir la red
while true; do
  read -p "¿Desea ejecutar Bitcoin en mainnet o regtest? (mainnet/regtest): " NETWORK
  if [[ "$NETWORK" == "mainnet" || "$NETWORK" == "regtest" ]]; then
    break
  else
    echo "[-] Entrada inválida. Por favor, ingrese 'mainnet' o 'regtest'."
  fi
done

# Crear archivo bitcoin.conf
if [[ -f "$BITCOIN_CONF" ]]; then
  read -p "[!] bitcoin.conf ya existe. ¿Sobrescribir? (si/no): " OVERWRITE
  if [[ "$OVERWRITE" != "si" ]]; then
    echo "[!] Omitiendo la creación de bitcoin.conf..."
  else
    echo "[+] Sobrescribiendo bitcoin.conf..."
  fi
fi

mkdir -p $BITCOIN_DIR
sudo chown -R ${SUDO_USER:-$USER}:${SUDO_USER:-$USER} $BITCOIN_DIR
cat <<EOF > $BITCOIN_CONF
# Establezca el mejor hash de bloque aquí:
# Para v25.0 en regtest y un buen hash para probar es...
# 00000002d38fc984fa25a057930af276c00a001428bd68b8216f826d580a382f
#assumevalid=

# Ejecutar en modo demonio sin un shell interactivo
daemon=1

# Añadir llamadas RPC
debug=rpc

# Establecer la autenticación RPC a lo que se estableció anteriormente
rpcauth=$RPC_AUTH

# Activar el servidor RPC
server=1

# Reducir el tamaño del archivo de registro en los reinicios
shrinkdebuglog=1

# Establecer regtest si es necesario
$( [[ "$NETWORK" == "regtest" ]] && echo "regtest=1" || echo "#regtest=1" )

# Activar el índice de búsqueda de transacciones, si el nodo podado está desactivado.
txindex=1

# Establecer una tarifa predeterminada para las Tx
fallbackfee=0.0001
EOF

# Establecer la propiedad del archivo de configuración al usuario
sudo chown ${SUDO_USER:-$USER}:${SUDO_USER:-$USER} $BITCOIN_CONF

# Informar al usuario dónde se encuentra el archivo de configuración
echo "[+] Su archivo bitcoin.conf ha sido creado en: $BITCOIN_CONF"

# Crear archivo de servicio systemd
if [[ ! -f "$SERVICE_FILE" ]]; then
  echo "[+] Creando archivo de servicio systemd para bitcoind..."
  cat <<EOF > $SERVICE_FILE
[Unit]
Description=Demonio de Bitcoin
After=network.target

[Service]
ExecStart=/usr/local/bin/bitcoind
Type=forking
Restart=on-failure

User=${SUDO_USER:-$USER}
Group=sudo

[Install]
WantedBy=multi-user.target
EOF
else
  echo "[!] El archivo de servicio Systemd ya existe. Omitiendo la creación."
fi

# Habilitar, recargar e iniciar el servicio systemd
systemctl enable bitcoind
systemctl daemon-reload
if ! systemctl is-active --quiet bitcoind; then
  systemctl start bitcoind
  echo "[+] El servicio bitcoind se inició."
else
  echo "[!] El servicio bitcoind ya se está ejecutando."
fi

# Terminado
cat <<"EOF"

[+] ¡Bitcoin Core está instalado, configurado y el servicio habilitado con éxito!
[+] ¡Hay que reiniciar el equipo para que algunos cambios tengan efecto!
[+] ¡Este es un ambiente de pruebas para ejecutar comandos de Bitcoin Core!
[+] ¡Ejecuta el siguiente script para completar el ejercicio!

[+]	"Si tienes dudas de cualquier comando ejecuta '$ bitcoin-cli help' "

        ⣿⣿⣿⣿⣿⣿⣿⣿⡿⠿⣿⣿⣿⣿⣿⣿⣿⣿⠀⠀⠀
        ⣿⣿⣿⣿⠟⠿⠿⡿⠀⢰⣿⠁⢈⣿⣿⣿⣿⣿⠀⠀
        ⣿⣿⣿⣿⣤⣄⠀⠀⠀⠈⠉⠀⠸⠿⣿⣿⣿⣿⠀
        ⣿⣿⣿⣿⣿⡏⠀⠀⢠⣶⣶⣤⡀⠀⠈⢻⣿⣿
        ⣿⣿⣿⣿⣿⠃⠀⠀⠼⣿⣿⡿⠃⠀⠀⢸⣿⣿
        ⣿⣿⣿⣿⡟⠀⠀⢀⣀⣀⠀⠀⠀⠀⢴⣿⣿⣿
        ⣿⣿⢿⣿⠁⠀⠀⣼⣿⣿⣿⣦⠀⠀⠈⢻⣿⣿
        ⣿⣏⠀⠀⠀⠀⠀⠛⠛⠿⠟⠋⠀⠀⠀⣾⣿⣿
        ⣿⣿⣿⣿⠇⠀⣤⡄⠀⣀⣀⣀⣀⣠⣾⣿⣿⣿⠀
        ⣿⣿⣿⣿⣄⣰⣿⠁⢀⣿⣿⣿⣿⣿⣿⣿⣿⣿⠀⠀
        ⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⠀v25.0⠀⠀⠀⠀⠀⠀⠀

[+] ¡Recuerda reiniciar el equipo para que algunos cambios tengan efecto!
[+] ¡Su nodo de Bitcoin ahora está instalado y en funcionamiento!
EOF

