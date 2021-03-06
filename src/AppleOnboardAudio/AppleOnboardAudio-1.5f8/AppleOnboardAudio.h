/*
 *  AppleOnboardAudio.h
 *  AppleOnboardAudio
 *
 *  Created by cerveau on Mon Jun 04 2001.
 *  Copyright (c) 2001 Apple Computer Inc. All rights reserved.
 *
 */

#ifndef __APPLEONBOARDAUDIO__
#define __APPLEONBOARDAUDIO__

#include "AudioHardwareCommon.h"
#include "AudioHardwareConstants.h"
#include "AudioDeviceTreeParser.h"
#include "AudioHardwareOutput.h"
#include "AudioHardwareInput.h"
#include "AudioHardwarePower.h"
#include "AppleDBDMAAudioDMAEngine.h"

enum {
    kOutMute = 0,
    kOutVolLeft = 1,
    kOutVolRight = 2,
    kPassThruToggle = 3,
    kInGainLeft = 4,
    kInGainRight = 5,
    kInputSelector = 6,
    kNumControls
};


class IOAudioControl;

class AppleOnboardAudio : public IOAudioDevice
{
    friend class AudioHardwareOutput;
    friend class AudioHardwareInput;
    friend class AudioHardwareDetect;
    friend class AudioHardwareMux;
    friend class AudioPowerObject;
    
    OSDeclareDefaultStructors(AppleOnboardAudio);

protected:
        //general controls : these are the default controls attached to a DMA audio engine
    IOAudioToggleControl	*outMute;
    IOAudioToggleControl	*playthruToggle;
    IOAudioLevelControl		*outVolLeft;
    IOAudioLevelControl		*outVolRight;
    IOAudioLevelControl		*inGainLeft;
    IOAudioLevelControl		*inGainRight;
    IOAudioSelectorControl 	*inputSelector;
        
        //globals for the driver
    bool	gIsMute;			// global mute (that is on all the ports)
    bool	gIsPlayThroughActive;		// playthrough mode is on
    UInt32      gVolLeft;
    UInt32      gVolRight;
    UInt32      gGainLeft;
    UInt32      gGainRight;
    bool 	gHasModemSound;
    bool 	gIsModemSoundActive;
    UInt32	gLastInputSourceBeforeModem;
    bool	gExpertMode;			//when off we are in a OS 9 like config. On we 
    UInt32	fMaxVolume;
    UInt32	fMinVolume;

            //we keep the engines around to have a cleaner initHardware
    AppleDBDMAAudioDMAEngine 	*driverDMAEngine;

        //Port Handler like info
    OSArray	*AudioDetects;
    OSArray	*AudioOutputs;
    OSArray	*AudioInputs;
    OSArray	*AudioSoftDSPFeatures;
    
        //Other objects
    AudioDeviceTreeParser 	*theAudioDeviceTreeParser;
    AudioPowerObject		*theAudioPowerObject;
    
        //Dynamic variable that handle the connected devices
    sndHWDeviceSpec currentDevices;
    
public:
            //Classical Unix funxtions
    virtual bool init(OSDictionary *properties);
    virtual void free();
    virtual IOService* probe(IOService *provider, SInt32*);

    bool     getMuteState();
    void     setMuteState(bool newMuteState);
            //Usefule getter
    virtual OSArray *getDetectArray();
            //IOAudioDevice subclass
    virtual bool initHardware(IOService *provider);
    virtual IOReturn AppleOnboardAudio::createDefaultsPorts();
    
	virtual IORegistryEntry * FindEntryByNameAndProperty (const IORegistryEntry * start, const char * name, const char * key, UInt32 value);

    static IOReturn volumeLeftChangeHandler(IOService *target, IOAudioControl *volumeControl, SInt32 oldValue, SInt32 newValue);
    virtual IOReturn volumeLeftChanged(IOAudioControl *volumeControl, SInt32 oldValue, SInt32 newValue);
    
    static IOReturn volumeRightChangeHandler(IOService *target, IOAudioControl *volumeControl, SInt32 oldValue, SInt32 newValue);
    virtual IOReturn volumeRightChanged(IOAudioControl *volumeControl, SInt32 oldValue, SInt32 newValue);
    
    static IOReturn outputMuteChangeHandler(IOService *target, IOAudioControl *muteControl, SInt32 oldValue, SInt32 newValue);
    virtual IOReturn outputMuteChanged(IOAudioControl *muteControl, SInt32 oldValue, SInt32 newValue);

    static IOReturn gainLeftChangeHandler(IOService *target, IOAudioControl *gainControl, SInt32 oldValue, SInt32 newValue);
    virtual IOReturn gainLeftChanged(IOAudioControl *gainControl, SInt32 oldValue, SInt32 newValue);

    static IOReturn gainRightChangeHandler(IOService *target, IOAudioControl *gainControl, SInt32 oldValue, SInt32 newValue);
    virtual IOReturn gainRightChanged(IOAudioControl *gainControl, SInt32 oldValue, SInt32 newValue);
    
    static IOReturn passThruChangeHandler(IOService *target, IOAudioControl *passThruControl, SInt32 oldValue, SInt32 newValue);
    virtual IOReturn passThruChanged(IOAudioControl *passThruControl, SInt32 oldValue, SInt32 newValue);

    static IOReturn inputSelectorChangeHandler(IOService *target, IOAudioControl *inputSelector, SInt32 oldValue, SInt32 newValue);
    virtual IOReturn inputSelectorChanged(IOAudioControl *passThruControl, SInt32 oldValue, SInt32 newValue);

    virtual IOReturn performPowerStateChange(IOAudioDevicePowerState oldPowerState, IOAudioDevicePowerState newPowerState,
                                                                                            UInt32 *microsecondsUntilComplete);

  //  IOReturn performDeviceWake();
   // IOReturn performDeviceSleep();
    
    virtual IOReturn setModemSound(bool state);
    virtual IOReturn callPlatformFunction( const OSSymbol * functionName,bool waitForFunction,
            void *param1, void *param2, void *param3, void *param4 );
    
    

protected:
            //Do the link to the IOAudioFamily 
//    virtual bool createPorts(IOAudioEngine *outputDMAEngine, IOAudioEngine *inputDMAEngine);
  //  virtual IOReturn createDefaultsPorts();
            //These will help to create the port config through the OF Device Tree
            
    IOReturn configureDMAEngines(IOService *provider);
    IOReturn parseAndActivateInit(IOService *provider);
    IOReturn configureAudioDetects(IOService *provider);
    IOReturn configureAudioOutputs(IOService *provider);
    IOReturn configureAudioInputs(IOService *provider);
    IOReturn configurePowerObject(IOService *provider);
    
    sndHWDeviceSpec getCurrentDevices();
    void setCurrentDevices(sndHWDeviceSpec devices);
    void changedDeviceHandler(UInt32 odevices);
public:
    virtual void setDeviceDetectionActive() = 0;
    virtual void setDeviceDetectionInActive() = 0;
protected:
            // The PRAM utility
    UInt8 VolumeToPRAMValue( UInt32 leftVol, UInt32 rightVol );
    void WritePRAMVol(  UInt32 volLeft ,  UInt32 volRight);
    
            //Hardware specific functions : These are all virtual functions and we have to 
            //to the work here
    virtual void 	sndHWInitialize(IOService *provider) = 0;
    virtual UInt32 	sndHWGetInSenseBits(void) = 0;
    virtual UInt32 	sndHWGetRegister(UInt32 regNum) = 0;
    virtual IOReturn   	sndHWSetRegister(UInt32 regNum, UInt32 value) = 0;

public:
    virtual  IOReturn   sndHWSetPowerState(IOAudioDevicePowerState theState) = 0;
    virtual  UInt32	sndHWGetConnectedDevices(void) = 0;
    virtual  UInt32 	sndHWGetProgOutput() = 0;
    virtual  IOReturn   sndHWSetProgOutput(UInt32 outputBits) = 0;

protected:    

            //activation functions
    virtual  UInt32	sndHWGetActiveOutputExclusive(void) = 0;
    virtual  IOReturn   sndHWSetActiveOutputExclusive(UInt32 outputPort ) = 0;
    virtual  UInt32 	sndHWGetActiveInputExclusive(void) = 0;
    virtual  IOReturn   sndHWSetActiveInputExclusive(UInt32 input )= 0;
    
            // control function
    virtual  bool   	sndHWGetSystemMute(void) = 0;
    virtual  IOReturn  	sndHWSetSystemMute(bool mutestate) = 0;
    virtual  bool   	sndHWSetSystemVolume(UInt32 leftVolume, UInt32 rightVolume) = 0;
    virtual  IOReturn   sndHWSetSystemVolume(UInt32 value) = 0;
    virtual  IOReturn	sndHWSetPlayThrough(bool playthroughstate) = 0;
    virtual IOReturn sndHWSetSystemInputGain(UInt32 leftGain, UInt32 rightGain) = 0;
    
            //Power Management

            //Identification
    virtual UInt32 	sndHWGetType( void ) = 0;
    virtual UInt32	sndHWGetManufacturer( void ) = 0;

};

#endif