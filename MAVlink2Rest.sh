BAIXAR O FIRMWARE
https://firmware.ardupilot.org/Copter/stable/SpeedyBeeF405AIO/

BAIXAR O UPLOADER

https://raw.github.com/ArduPilot/ardupilot/master/Tools/scripts/uploader.py

python Tools/scripts/uploader.py --port /dev/ttyACM0 build/Pixracer/bin/arducopter.apj
After starting the script, press the reset button on your device to make it enter bootloader mode.




NO ORANGEPI NO DRONE USAR OU MAVPROXY OU MAVLINK2REST


##MAVPROXY
sudo apt install python3-pip python3-dev
pip3 install mavproxy pymavlink flask Werkzeug

mavproxy.py --master=/dev/ttyACM0 --baudrate 115200 --out=udpin:0.0.0.0:14550


Dentro do terminal do MAVProxy, carregue e inicie o módulo REST: 
mavlink
module load restserver
restserver start

Acesso: Por padrão, os dados estarão disponíveis 
em JSON no endereço http://localhost:5000/rest/mavlink

##MAVLINK2REST

https://github.com/mavlink/mavlink2rest

docker run --rm --init -p 8088:8088 -p 14550:14550/udp --name mavlink2rest mavlink/mavlink2rest

PARA EXECUTAR NO PROPRO ORANGEPI

docker run -d \
  --name mavlink2rest \
  --restart always \
  --net=host \
  --privileged \
  -v /dev:/dev \
  patrickelectric/mavlink2rest:latest \
  -c "serial:/dev/ttyACM0:115200"


./mavlink2rest-linux-x86_64 -c "serial:/dev/ttyACM0:115200"



MISSIONPLANER AGORA EH COCKPIT VIA WEB  

PARA EXECUTAR NO PC E ACESSAR O DRONE REMOTO

docker run -d \
  --name cockpit \
  --restart always \
  --net=host \
  bluerobotics/cockpit:latest








Ligar o Cockpit ao MAVLink2Rest Ao abrir o Cockpit pela primeira vez, ele tentará detetar o backend automaticamente. Se não o fizer: Vá às Settings ícone da engrenagem. Procure por MAVLink Sources ou Endpoints. Adicione o endereço do seu MAVLink2Rest: http://localhost:8088/v1/mavlink. O estado deve mudar para Connected e verá a telemetria do seu drone horizonte artificial, GPS, etc..


