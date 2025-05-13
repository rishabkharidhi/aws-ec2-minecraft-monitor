#!/bin/bash

cd /opt/minecraft/server/
rm -f stop
rm -f start
rm -f monitor

# Create monitor script
cat <<EOF > monitor
#!/bin/bash

SSM_SHUTDOWNTIMER=$(aws ssm get-parameter --name "/mc/shutdowntimer" --query "Parameter.Value" --output text)
DEFAULT_SHUTDOWNTIMER=900
if [ $? -eq 0 ] && [[ "$SSM_SHUTDOWNTIMER" =~ ^[0-9]+$ ]] && [ "$SSM_SHUTDOWNTIMER" -gt 0 ]; then
    SHUTDOWNTIMER=$SSM_SHUTDOWNTIMER
else
    SHUTDOWNTIMER=$DEFAULT_SHUTDOWNTIMER
fi

# MONITOR_IP="13.56.206.173"
MONITOR_PORT="25565"
echo "Monitoring connection and shutdown conditions for \$MONITOR_IP:\$MONITOR_PORT..."

lastdisconnect=0

while true; do
    mc_status=$(systemctl is-active minecraft.service)

    if [ "\$mc_status" != "active" ]; then
        connection=$(ss -tn state syn-recv "( sport = :$MONITOR_PORT )")
        if [[ -n "\$connection" ]]; then
            echo "\$(date): Connection requested to \$MONITOR_IP:\$MONITOR_PORT but server is off"
            echo "\$(date): Starting Minecraft server"
            sudo systemctl start minecraft.service
        fi
    else
        connections=\$(ss -tn state established "( sport = :\$MONITOR_PORT )" | grep -c ESTAB)
        if [ "\$connections" -eq 0 ]; then
            echo "0 connections"
            if [ "\$lastdisconnect" -eq 0 ]; then
                echo "no players on server, starting timer..."
                lastdisconnect=\$(date +%s)
            else
                now=\$(date +%s)
                elapsed=\$((now - lastdisconnect))
                echo "no players again, check if timer has reached time"
                echo "shutdowntimer: \$SHUTDOWNTIMER timer: \$elapsed"
                if [ "\$elapsed" -ge "\$SHUTDOWNTIMER" ]; then
                    echo "timer has reached time, begin shutdown logic"
                    echo "Stop Minecraft server"
                    sudo ./stop
                    sleep 20
                    break
                fi
            fi
        else
            echo "connections exist"
            lastdisconnect=0
        fi
    fi

    sleep 2
done
EOF

chmod +x monitor

# Create start script
cat <<EOF > start
#!/bin/bash
RAM=\$(aws ssm get-parameter --name "/mc/ram" --query "Parameter.Value" --output text)
DEFAULT_RAM="1300M"
echo "starting server!"
if [ \$? -eq 0 ] && [[ "\$RAM" =~ ^[0-9]+$ ]] && [ "\$RAM" -gt 0 ]; then
    ram_size="\${RAM}M"
else
    ram_size="\$DEFAULT_RAM"
fi
echo "ram: \$ram_size"
exec java -Xmx1200M -Xms1200M -jar server.jar nogui
EOF

chmod +x start

# Create stop script
cat <<EOF > stop
#!/bin/bash
echo "/stop" > /run/minecraft.stdin
EOF

# Create systemd service files
cd /etc/systemd/system/
rm -f minecraft.service minecraft.socket monitor_minecraft.service

cat <<EOF > minecraft.service
[Unit]
Description=Minecraft Server on start up

[Service]
User=minecraft
WorkingDirectory=/opt/minecraft/server
ExecStart=/opt/minecraft/server/start
Restart=on-failure
Sockets=minecraft.socket
StandardInput=socket
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

cat <<EOF > minecraft.socket
[Unit]
PartOf=minecraft.service

[Socket]
ListenFIFO=%t/minecraft.stdin

[Install]
WantedBy=sockets.target
EOF

cat <<EOF > monitor_minecraft.service
[Unit]
Description=Monitor MC server for network connections
After=network-online.target
Wants=network-online.target

[Service]
User=ec2-user
WorkingDirectory=/opt/minecraft/server
ExecStart=/opt/minecraft/server/monitor
Restart=always
StandardInput=null

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable minecraft.service
sudo systemctl start minecraft.service
sudo systemctl enable monitor_minecraft.service
sudo systemctl start monitor_minecraft.service
