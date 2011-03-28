/* jLamp.pde - Jupps adjustable LED Lamp */

#include <avr/interrupt.h>
#include <avr/io.h>

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
#define FADE_SPEED_MANUAL                20
#define FADE_SPEED_RANDOM               100

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

/* all URLs on this server will start with /buzz because of how we
 * define the PREFIX value.  We also will listen on port 80, the
 * standard HTTP service port */
#define PREFIX "/jlamp"

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
      fadeStep();
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
void fadeStep(){
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
        fadeStep();
      }
    }
    break;
    
    /* random mode: randomly choose another color, slowly fade there */
   case RANDOM:
    fading = true;
    if(target_redVal == redVal && target_greenVal == greenVal && target_blueVal == blueVal && target_whiteVal == whiteVal) {
      target_redVal = random(0,32);
      target_greenVal = random(0,32);
      target_blueVal = random(0,32);
      target_whiteVal = random(0,32);
    } else if(fade_counter == FADE_SPEED_RANDOM) {
      fade_counter++; 
      fadeStep();
    }
    break;
  }
  return;
};

/* this is the default webserver callback function */
void changePWMCmd(WebServer &server, WebServer::ConnectionType type, char *, bool)
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
"function changeColor(color) { $.post('/jlamp', { chColor: color.substring(1, 7)} ); }\n"
"function changeMode(mode) { $.post('/jlamp', {chMode: mode} ); }\n"
"$(document).ready(\n"
"  function() {\n"
"    $('#mode').change(function() {changeMode($(this).val())});"
"    $('#picker').farbtastic(function(color) {  \n"
"      changeColor(color); $('#color').val(color);  $('#color').css({'background-color':color});\n"
"    }\n"
"  )}\n"
");\n"
"</script>\n"
"</head>\n"
"<body style='font-size:62.5%;'>\n"
"<h1>jlamp Control Panel</h1>\n"
"<form action = "" style=\"width:400px;\">\n"
"Mode: <select id=\"mode\"><option value=\"manual\">manual</option>\n"
"<option name=\"random\">random</option>\n"
"<option name=\"music\">music</option>\n"
"</form>\n"
"<form action=\"\" style=\"width: 400px;\">\n"
"<div class=\"form-item\"><label for=\"color\">Color:</label><input type=\"text\" id=\"color\" name=\"color\" value=\"#00000\" /></div><div id=\"picker\"></div>\n" 
"</form>\n"
"</body>\n"
"</html>\n";

    server.printP(message);
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
  webserver.setDefaultCommand(&changePWMCmd);

  /* start the server to wait for connections */
  webserver.begin();
  
  /* Debugging output over serial console */
//  Serial.begin(9600);
  
}

void loop()
{
  // process incoming connections one at a time forever
//  Serial.print("processing connection ...");
  webserver.processConnection();
//  Serial.println(" done");
  if(mode == MANUAL) {
  
  } else if (mode == RANDOM) {
    // TODO implement RANDOM mode
  } else if (mode == MUSIC) {
    // TODO implement MUSIC mode
  }
}
