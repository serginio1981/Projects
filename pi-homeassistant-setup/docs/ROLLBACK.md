# ROLLBACK — revertir pi-homeassistant-setup por completo

Para cuando algo salió mal y quieres volver al estado anterior: **una Pi que
solo es servidor de impresión**. Los pasos van del más superficial al más
profundo; muchas veces basta con los dos primeros. Todos son seguros para el
servidor de impresión: nada de esto toca CUPS ni Avahi.

Tiempo estimado total: 10 minutos.

---

## 1. Detener y eliminar el contenedor de Home Assistant

```bash
sudo docker stop homeassistant
sudo docker rm homeassistant
```

(Si usaste otro `HA_CONTAINER_NAME`, sustitúyelo.) Con esto HA deja de
consumir RAM/CPU y de escribir en la microSD. **La configuración de HA
sobrevive** en `/opt/homeassistant/config` por si quieres volver.

Verifica ya mismo la impresión (lo importante):

```bash
lpstat -p                                   # cola idle/enabled
avahi-browse -rt _ipp._tcp | grep '^=' | head -3   # anuncio AirPrint visible
```

## 1b. Si desplegaste el Matter Server opcional

```bash
sudo docker stop matter-server
sudo docker rm matter-server
sudo docker image rm ghcr.io/matter-js/python-matter-server:stable
sudo rm -rf /opt/homeassistant/matter-server    # borra credenciales de emparejamiento Matter
```

## 2. Borrar la imagen de Home Assistant (libera ~1.5 GB)

```bash
sudo docker image rm ghcr.io/home-assistant/home-assistant:stable
sudo docker image prune -f
```

## 3. Borrar la configuración y el compose (opcional, destructivo para HA)

Solo si no piensas volver a HA — esto borra usuarios, automatizaciones e
histórico:

```bash
sudo rm -rf /opt/homeassistant
```

## 4. Revertir la rotación de logs de Docker

- Si `30-hardening-sd.sh` **creó** `/etc/docker/daemon.json` (no existía
  antes):

  ```bash
  sudo rm /etc/docker/daemon.json
  sudo systemctl restart docker
  ```

- Si el archivo **ya existía** y el script lo fusionó, hay respaldo:

  ```bash
  sudo cp /etc/docker/daemon.json.bak /etc/docker/daemon.json
  sudo systemctl restart docker
  ```

(Este paso es inocuo: la rotación de logs no molesta aunque se quede.)

## 5. Desinstalar Docker (solo si lo instaló este proyecto)

Si Docker no existía antes y no lo usas para nada más:

```bash
sudo systemctl disable --now docker
sudo apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo apt-get autoremove -y
sudo rm -f /etc/apt/sources.list.d/docker.sources /etc/apt/keyrings/docker.asc
sudo rm -rf /var/lib/docker /var/lib/containerd    # borra TODAS las imágenes/volúmenes de Docker
```

**No hagas este paso** si tenías Docker de antes para otra cosa: el último
`rm -rf` borra todos los contenedores e imágenes de la máquina, no solo HA.

## 6. Borrar el estado de este proyecto

```bash
sudo rm -rf /var/lib/pi-homeassistant-setup
```

## 7. Verificación final: la Pi vuelve a ser solo servidor de impresión

```bash
systemctl is-active cups avahi-daemon        # ambos: active
lpstat -p                                    # cola idle/enabled, accepting
avahi-browse -rt _ipp._tcp | grep '^='       # anuncio AirPrint publicado
free -m                                      # RAM liberada
```

Y la prueba definitiva: **imprime una página desde el iPhone**.

Si la impresión NO funciona llegado este punto, el problema no lo introdujo
este proyecto (nada de lo anterior toca CUPS/Avahi): restaura tu respaldo de
`/etc/cups/ppd/`, `/etc/cups/printers.conf` y los `.service` de Avahi, o
reejecuta el instalador de tu servidor de impresión, y reinicia `cups` y
`avahi-daemon`.
