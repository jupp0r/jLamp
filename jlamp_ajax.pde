/* jLamp.pde - Jupps adjustable LED Lamp */

#include <avr/interrupt.h>
#include <avr/io.h>

#include <Wire.h>
#include <SPI.h>

///#define WEBDUINO_SERIAL_DEBUGGING 1

#include "Ethernet.h"
#include "WebServer.h"

#include "jlamp_ajax.h"

/* define color channel pins */
#define WHITE_PIN     3
#define RED_PIN       9
#define GREEN_PIN     6
#define BLUE_PIN      5

/* fading speeds, lower = faster, too slow might look glitchy*/
#define FADE_SPEED_MANUAL               20
#define FADE_SPEED_RANDOM               20
#define TEMPERATURE_READ_SPEED         1000

/* PWM lookup table to linearize LED Brightness. 
Mathematica Code : Table[Floor[255*(i/32)^(1.5) + 0.5], {i, 1, 32}] 
Adjust the 1.5 to an constant that works for your LEDs
*/
static uint8_t pwm_lookup[32] = {1, 4, 7, 11, 16, 21, 26, 32, 38, 45, 51, 59, 66, 74, 82, 90, 99, \
108, 117, 126, 136, 145, 155, 166, 176, 187, 198, 209, 220, 231, 243, \
255};

// no dead beef here
static uint8_t mac[6] = { 0x02, 0xAA, 0xBB, 0xCC, 0x00, 0x22 };

static uint8_t ip[4] = { 172, 31, 1, 3 }; // change this to suit your network

mode_t mode = MANUAL;

/* actual PWM values, being used right now */
uint8_t redVal = 0;
uint8_t greenVal = 0;
uint8_t blueVal = 0;
uint8_t whiteVal = 0;

/* target PWM values (index into lookup table), traversing */
uint8_t target_redVal = 0;
uint8_t target_greenVal = 0;
uint8_t target_blueVal = 0;
uint8_t target_whiteVal = 0;

/* counter and mode flag used for fading to the right color */
boolean fading = false;
uint16_t fade_counter = 0;

/* temperature read timing counter */
uint16_t temp_counter = 0;
float temperature = 0.0f;

/* all URLs on this server will start with /buzz because of how we
 * define the PREFIX value.  We also will listen on port 80, the
 * standard HTTP service port */
#define PREFIX "/jlamp"

#define LM75_ADDR 0x48

void readTemp() {
  
  uint8_t temp_msb = 0;
  uint8_t temp_lsb = 0;
  
  temp_counter = 0;
  
  Wire.beginTransmission(LM75_ADDR);
  Wire.requestFrom(LM75_ADDR,2);
  
  if(Wire.available()) {
    temp_msb = Wire.receive();
    temp_lsb = Wire.receive(); 
  }
  
  Wire.endTransmission();
  
  Serial.print("Temperature: ");
  Serial.print(temp_msb,DEC);
  Serial.println((temp_lsb&0x80)>>7==1?".5 C":".0 C");

  temperature = temp_msb + 0.5 * (float)((temp_lsb&0x80) >> 7);
  
}

/* RGB to RGBW composition */
uint8_t computeWhiteVal(uint8_t red, uint8_t green, uint8_t blue) {
  uint8_t cmax = max(max(red,green),blue);
  uint8_t cmin = min(min(red,green),blue);
  
  /* computing saturation */
  uint8_t saturation = cmax-cmin;
  
  uint8_t white = ((31-saturation)*(31-4)+4)/31;
  
  return white;
}

/* switch to another mode */
void switchMode(mode_t newMode) {
  switch(newMode) {
    case MANUAL:
      mode = MANUAL;
      break;
    case RANDOM:
      mode = RANDOM;
      target_redVal = random(0,32);
      target_greenVal = random(0,32);
      target_blueVal = random(0,32);
      target_whiteVal = random(0,32);
      fadeStepRGB();
      break;
    case MUSIC:
      mode = MUSIC;
      break;
    default:
      // TODO: do some error handling
      ;
  }
}

/* fade one step towards the target color */
void fadeStepRGB(){
    if(target_redVal > redVal) {
      redVal++;
      analogWrite(RED_PIN, pwm_lookup[redVal]);
    } else if(target_redVal < redVal) {
      redVal--;
      analogWrite(RED_PIN, pwm_lookup[redVal]);
    } else if(target_greenVal > greenVal) {
      greenVal++;
      analogWrite(GREEN_PIN, pwm_lookup[greenVal]);
    } else if(target_greenVal < greenVal) {
      greenVal--;      
      analogWrite(GREEN_PIN, pwm_lookup[greenVal]);
    } else if(target_blueVal > blueVal) {
      blueVal++;
      analogWrite(BLUE_PIN, pwm_lookup[blueVal]);
    } else if(target_blueVal < blueVal) {
      blueVal--;
      analogWrite(BLUE_PIN, pwm_lookup[blueVal]);
    } else if(target_whiteVal > whiteVal) {
      whiteVal++;
      analogWrite(WHITE_PIN, pwm_lookup[whiteVal]);
    } else if(target_whiteVal < whiteVal) {
      whiteVal--;
      analogWrite(WHITE_PIN, pwm_lookup[whiteVal]);      
    }
}

/* used for dimming the leds */
ISR(TIMER2_OVF_vect) {
  switch(mode){
   /* manual mode, fade to desired color parallel to rgb cube axes */
   case MANUAL:
    fade_counter ++;
    if (fade_counter == FADE_SPEED_MANUAL) {
      fade_counter = 0;
      if(target_redVal == redVal && target_greenVal == greenVal && target_blueVal == blueVal && target_whiteVal == whiteVal) {
        fading = false;
        return;
      } else {
        fading = true;
        fadeStepRGB();
      }
    }
    break;
    
    /* random mode: randomly choose another color, slowly fade there */
   case RANDOM:
    fading = true;
    fade_counter++;
    if(target_redVal == redVal && target_greenVal == greenVal && target_blueVal == blueVal && target_whiteVal == whiteVal) {
      target_redVal = random(0,32);
      target_greenVal = random(0,32);
      target_blueVal = random(0,32);
      target_whiteVal = random(0,32);
    } else if(fade_counter == FADE_SPEED_RANDOM) {
      fade_counter = 0;
      fadeStepRGB();
    }
    break;
  }
  
  temp_counter++;
  return;
};

/* this is the default webserver callback function */
void defaultWebCmd(WebServer &server, WebServer::ConnectionType type, char * url_tail, bool tail_complete)
{
  uint32_t hexColor;
  if (type == WebServer::POST)
  {
    bool repeat;
    char name[16], value[16];
    do {
      repeat = server.readPOSTparam(name, 16, value, 16);
      /* check for parameters */
      if (strcmp(name, "chColor") == 0) { /* chColor command */
         hexColor = strtoul(value, NULL, 16);
         target_redVal =   map((hexColor & 0xFF0000) >> 16, 0, 255, 0, 31);
         target_greenVal = map((hexColor & 0xFF00) >> 8, 0, 255, 0, 31);
         target_blueVal =  map((hexColor & 0xFF), 0, 255, 0, 31);
         target_whiteVal = computeWhiteVal(target_redVal,target_greenVal, target_blueVal);
      } else if(strcmp(name, "chMode") == 0) { /* chMode command */
         if(strcmp(value, "manual") == 0) {
           switchMode(MANUAL);
         } else if (strcmp(value, "random") == 0) {
           switchMode(RANDOM);
         } else if (strcmp(value, "music") == 0) {
           switchMode(MUSIC);
         } else {
           /* unknown mode, switch to manual */
           Serial.println("unknown Mode error");
           switchMode(MANUAL);
         }
      }
   } while (repeat);
    // after procesing the POST data, tell the web browser to reload
    // the page using a GET method. 
    server.httpSeeOther(PREFIX);
  //server.httpSuccess();
    return;
  }

  /* for a GET or HEAD, send the standard "it's all OK headers" */
  server.httpSuccess();

  /* we don't output the body for a HEAD request */
  if (type == WebServer::GET)
  {
    /* store the HTML in program memory using the P macro */
      P(message) = 
"<!DOCTYPE html><html><head>\n"
"<title>jLamp Control</title>\n"
" <script type=\"text/javascript\" src=\"http://172.31.1.1/~jupp/farbtastic/jquery.js\"></script>\n"
" <script type=\"text/javascript\" src=\"http://172.31.1.1/~jupp/farbtastic/farbtastic.js\"></script>\n"
" <link rel=\"stylesheet\" href=\"http://172.31.1.1/~jupp/farbtastic/farbtastic.css\" type=\"text/css\" />\n"
" <script type=\"text/javascript\" charset=\"utf-8\">\n"
"var picker;"
"var locked = false;"
"function changeColor(color) { if(locked == false) {$.post('/jlamp', { chColor: color.substring(1, 7)} ); } }\n"
"function changeMode(mode) { if(locked == false) {$.post('/jlamp', {chMode: mode} );  } }\n"
"function loadState() {\n"
"$.getJSON(\n"
        "\"/jlamp/status\",\n"
        "function(status) {\n"
        "  locked = true;\n"
        "  picker.setColor('#' + status.target_redVal.toString(16) + status.target_greenVal.toString(16) + status.target_blueVal.toString(16));\n"
        "  $('#mode').val(status.mode).attr('selected', 'selected');\n"
        "  $('#temp').text(status.temperature.toString() + \"C\");\n"
        "  locked = false;\n"
        "  setTimeout('loadState()',5000);\n"
        "});\n"
    "};\n"
"$(document).ready(\n"
"  function() {\n"
"    $('#mode').change(function() {changeMode($('#mode option:selected').val())});"
"    picker = $.farbtastic('#picker');"
"    picker.linkTo(function(color) {  \n"
"      changeColor(color); $('#color').val(color);  $('#color').css({'background-color':color});\n"
"    });\n"
"    loadState();\n"
"  }\n"
");\n"
"</script>\n"
"</head>\n"
"<body style='font-size:100%;'>\n"
"<h1>jlamp Control Panel</h1>\n"
"<form action = "" style=\"width:400px;\">\n"
"Mode: <select id=\"mode\"><option name=\"manual\">manual</option>\n"
"<option name=\"random\">random</option>\n"
"<option name=\"music\">music</option>\n"
"</form>\n"
"<form action=\"\" style=\"width: 400px;\">\n"
"<div class=\"form-item\"><label for=\"color\">Color:</label><input type=\"text\" id=\"color\" name=\"color\" value=\"#00000\" /></div><div id=\"picker\"></div>\n" 
"</form>\n"
"Temperature: <div id=temp></div>\n"
"</body>\n"
"</html>\n";

      server.printP(message);
  }
}

void statusCmd(WebServer &server, WebServer::ConnectionType type, char * url_tail, bool tail_complete) {
   if (type == WebServer::POST)
  {
    server.httpFail();
  } else {
  /* for a GET or HEAD, send the standard "it's all OK headers" */
    server.httpSuccess();
      server.print("{\n\"mode\": \"");
      server.print((mode == MANUAL)?"manual":(mode == RANDOM)?"random":(mode==MUSIC)?"music":"unknown");
      server.print("\",\n");
      server.print("\"target_redVal\": ");
      server.print((uint16_t)pwm_lookup[target_redVal]);
      server.print(",\n");
      server.print("\"target_greenVal\": "); 
      server.print((uint16_t)pwm_lookup[target_greenVal]);
      server.print(",\n");
      server.print("\"target_blueVal\": ");
      server.print((uint16_t)pwm_lookup[target_blueVal]);
      server.print(",\n");
      server.print("\"target_whiteVal\": ");
      server.print((uint16_t)pwm_lookup[target_whiteVal]);
      server.print(",\n");
      server.print("\"redVal\": ");
      server.print((uint16_t)pwm_lookup[redVal]);
      server.print(",\n");
      server.print("\"greenVal\": ");
      server.print((uint16_t)pwm_lookup[greenVal]);
      server.print(",\n");
      server.print("\"blueVal\": ");
      server.print((uint16_t)pwm_lookup[blueVal]);
      server.print(",\n");
      server.print("\"whiteVal\": ");
      server.print((uint16_t)pwm_lookup[whiteVal]);
      server.print(",\n");
      server.print("\"temperature\": ");
      server.print(temperature);
      server.print( "\n}\n");
  }
}

WebServer webserver(PREFIX, 80);

void setup()
{
  /* enable timer 2 overflow interrupt (used for fading the leds to target colors) */
  TIMSK2 |= (1<<TOIE2);
  
  /* random seed from analog input */
  randomSeed(analogRead(0));
  
  /* set the PWM output for colors */
  pinMode(RED_PIN, OUTPUT);
  pinMode(GREEN_PIN, OUTPUT);
  pinMode(BLUE_PIN, OUTPUT);
  pinMode(WHITE_PIN, OUTPUT);

  // setup the Ehternet library to talk to the Wiznet board
  Ethernet.begin(mac, ip);

  /* register our default command (activated with the request of
   * http://x.x.x.x/jlamp */
  webserver.setDefaultCommand(&defaultWebCmd);

  webserver.addCommand("status",&statusCmd);

  /* start the server to wait for connections */
  webserver.begin();
  
  /* Debugging output over serial console */
 Serial.begin(9600);
 Serial.println("Starting Serial Logging");
 /* TWI for LM75 temperature sensor */
 Wire.begin();
  
}

void loop()
{
  // process incoming connections one at a time forever
//  Serial.print("processing connection ...");
  webserver.processConnection();
//  Serial.println(" done");
   if(temp_counter > TEMPERATURE_READ_SPEED) {
     readTemp();
    }
  
  if(mode == MANUAL) {
  
  } else if (mode == RANDOM) {
    // TODO implement RANDOM mode
  } else if (mode == MUSIC) {
    // TODO implement MUSIC mode
  }
}
