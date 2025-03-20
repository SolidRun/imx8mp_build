/* Copyright (C) 2021, Solidrun, Alvaro Karsz <alvaro.kars@solid-run.com>
 * SPDX-License-Identifier:      MIT
 *
 *
 *
 * This code writes to fuses using nvmem driver.
 * Common offsets:
 * 0x90 For I.MX 8M Nano first MAC Address
*/


#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <stdint.h>
#include <string.h>


#define BUFFER_SIZE 8
#define MAC_LENGTH 12
#define MAX_STR_LENGTH 300

int validate_mac_str(char *mac);
void print_usage();
int str_starts_with(char *full, char *part);
int str_includes(char *full, char *part);

int main(int argc, char *argv[])
{
	int offset = -1,
		i,j,k = 0,
		mode = -1; /*mode=0 read, mode=1 write*/
	FILE *fp;
	uint8_t mac_word_1[BUFFER_SIZE / 2],
		mac_word_2[BUFFER_SIZE / 2],
		tmp;
	char ch[MAC_LENGTH],
	path[MAX_STR_LENGTH],
	mac_str[MAX_STR_LENGTH],
	mac_segment_holder[3] = "00";


	/*Initialize both arrays with null in element 0, if the first element is 0 after saving arguments, print usage*/
	path[0] = '\0';
	mac_str[0] = '\0';


	/*handle arguments*/	
	for(i = 1; i < argc ; i ++ ) {
		if(strcmp(argv[i], "--read") == 0) {
			mode = 0;
		} else if(strcmp(argv[i], "--write") == 0) {
			mode = 1;
		} else if ( (str_starts_with(argv[i],"--offset=0x") == 0 || str_starts_with(argv[i],"--offset=0X") == 0) && strlen(argv[i]) > 11 ) {
			offset = strtol(argv[i] + 11, NULL, 16);/*remove --ofset=0x*/
		} else if(str_starts_with(argv[i], "--path=") == 0) {
			strcpy(path, argv[i] + 7); /*remove --path=*/
		} else if(str_starts_with(argv[i], "--mac=") == 0) {
			strcpy(mac_str, argv[i] + 6); /*remove --mac=*/
		}
	}

	/*validate arguments*/

	if(mode == -1) {/*no mode*/
		print_usage();
	}

	if(path[0] == '\0') { /*no path*/
		print_usage();
	}
	
	if(offset == -1) { /*no offset*/
		print_usage();
	}

	if(mode && mac_str[0] == '\0') {/*write without mac*/
		print_usage();
	}
	

	/*make sure path has the words "nvmem", "ocotp", "imx"*/
	if(str_includes(path, "nvmem") == -1 || str_includes(path, "ocotp") == -1 || str_includes(path, "imx") == -1 ) {
		printf("ERROR!\nPath must include the words 'ocotp', 'nvmem' and 'imx'\n");
		return -1;
	} 


	/*check if path exist*/
	if( access( path, F_OK ) != 0 ) {
		printf("ERROR!\nPath not exist!\n");
		return -1;
	}
	
	

	/*check MAC address for write mode and prepare for write action*/
	if(mode) {
		if (validate_mac_str(mac_str) != 0) {
			printf("ERROR\nInvalid MAC Address\nMake sure the MAC address is in capital letters and has no as prefix\n");
			return -1;
		}

		/*
		 * convert to hex
		 * the write is made in 2 different write actions, 1 for every word, so push data to 2 different buffers, each BUFFER_SIZE/2 long.
		 * Since MAC length is 12 and the needed length is 16, pad the MAC address with leading zeros (little endian)
		 * */


		/*pad the mac address by pushing zeros to the second buffer*/
		for(i = 0 ; i < (BUFFER_SIZE - MAC_LENGTH / 2) ; i++) { /* /2 since we write 2 hex digits */
			/*
			 * mac_segment_holder default value is 00
			 * 00 value won't write to fuses.
			 * */
			tmp = strtol(mac_segment_holder, NULL, 16);
			mac_word_2[BUFFER_SIZE/2 - 1 - i] = tmp;
		}


		/*now convert input mac to hex and push to buffers*/
		for(i = 0 ; i < BUFFER_SIZE ; i++) {
			for(j  = 0 ; j < 2 ; j ++) {
				mac_segment_holder[j] = mac_str[j + k];
			}

			tmp = strtol(mac_segment_holder, NULL, 16);
			k += 2;
			
			if( i < (BUFFER_SIZE - MAC_LENGTH/2) ) {
				mac_word_2[ (BUFFER_SIZE - MAC_LENGTH/2) - 1 - i ] = tmp;
			} else {
				mac_word_1[BUFFER_SIZE/2 + (BUFFER_SIZE - MAC_LENGTH/2) - 1 - i] = tmp;
			}
		}
	}


	/*
	 * open the file with relevant access type
	 * Read access for read mode
	 * Read + Write access for write mode (the MAC is read after the write action)
	 **/

	if((fp = fopen( path , mode ? "r+" : "r")) == NULL ) {
		printf("ERROR\nCould not open file\n");
		return -1;
	}


  	/*seek first word offset*/ 
	if(fseek(fp, offset, SEEK_SET) != 0) {
		printf("ERROR\nCould not seek file!\n");
		return -1;
	}


	/*if write mode - write the buffers*/
	if(mode) {

		/*write first word*/
		if(fwrite(mac_word_1, 1, BUFFER_SIZE / 2 , fp) != BUFFER_SIZE / 2 ) {
			printf("ERROR\nCould not write MAC address\n");
			return -1;
		}

		/*add delay - just in case*/
		usleep(10);


		/*seek the second word offset*/
		if(fseek(fp, offset + 0x4, SEEK_SET) != 0) {
			printf("ERROR\nCould not seek file!\n");
			return -1;
		}

		/*write the second word*/
		if(fwrite(mac_word_2, 1, BUFFER_SIZE / 2, fp) != BUFFER_SIZE / 2) {
			printf("ERROR\nCould not write MAC address\n");
			return -1;
		}


		/*flush file before reading, just in case*/
		if(fflush(fp) != 0) {
			printf("ERROR\nCould not flush file after write action.\n");
			return -1;
		}

		/*do seek again, so code will read the written value*/
		if(fseek(fp, offset, SEEK_SET) != 0) {
			printf("ERROR\nCould not seek file!\n");
			return -1;
		}

	}


	/*read file*/
	for(i = MAC_LENGTH / 2 - 1 ; i >= 0; i--) {
		ch[i] = fgetc(fp);

	}

	/*close file*/
	fclose(fp);


	/*print value*/
	for(i = 0 ; i < MAC_LENGTH / 2; i++) {
		printf("%02x", ch[i]);
	}
	printf("\n");
   	return 0;
}



int validate_mac_str(char *mac) {
	int i,
	    size = strlen(mac);

	/*invalid MAC addres length*/
	if(size != MAC_LENGTH) {
		return -1;
	}

	for(i = 0; i < size; i ++ ) {
		if((mac[i] < '0' || mac[i] > '9') && (mac[i] < 'a' || mac[i] > 'f')) {
			return -1;		
		}
	
	}

	return 0;
}

void print_usage() {
	/*print usage string and exit with error code*/
	const char usage[] = "\n \
Usage Options:\n\n \
--read/write - Mode, Read/Write fuses, Required\n \
--path - path to fuses in sysfs, nvmem driver, Required\n \
--offset - file offset, Required\n \
--mac - MAC Address to fuse, required in write mode\n\n \
Examples:\n \
Read: <this command> --read --path=/sys/devices/platform/soc@0/{SOME_ID}.bus/{SOME_ID}.ocotp-ctrl/imx-ocotp0/nvmem --offset=0x90\n \
Write: <this_command> --write --mac=0123456789ab --path=/sys/devices/platform/soc@0/{SOME_ID}.bus/{SOME_ID}.ocotp-ctrl/imx-ocotp0/nvmem --offset=0x50\n \
After a Write, the written value will be read and echo to stdout.\n\n \
Common Offsets:\n \
0x90 For I.MX 8M Nano First MAC Address.\n \
0x90 For I.MX 8M Plus First MAC Address.\n\n \
Critical points:\n \
offset/mac/path arguments should follow the format in examples, offset=0xSOMETHING, path=/absolute/path, mac=MAC_ADDRESS no whitespaces, remove ':' from MAC address before calling this function.\n \
MAC Address must be lower case. --mac=0045787aaaca is OK, --mac=000000457A4C is not OK.\n\n \
Arguments order is NOT important\n";

	printf("%s", usage);
	exit(-1);
}


int str_starts_with(char *full, char *part) {
	return 	strncmp(full, part, strlen(part)) == 0 ? 0 : -1;
}

int str_includes(char *full, char* part) {
	return strstr(full, part) != NULL ? 0 : -1;
}

