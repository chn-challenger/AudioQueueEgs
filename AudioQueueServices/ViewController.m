//
//  ViewController.m
//  AudioQueueServices
//
//  Created by John Nastos on 7/7/15.
//  Copyright (c) 2015 John Nastos. All rights reserved.
//

#import "ViewController.h"
//enum of states
typedef NS_ENUM(NSUInteger, AudioQueueState) {
    AudioQueueState_Idle,
    AudioQueueState_Recording,
    AudioQueueState_Playing,
};
//important framework
@import AVFoundation;

@interface ViewController ()

@property AudioQueueState currentState;
@property (strong, nonatomic) NSURL *audioFileURL;

@end

#define NUM_BUFFERS 10

static SInt64 currentByte;
static AudioStreamBasicDescription audioFormat;  //to be setup in audio setup
static AudioQueueRef queue;
static AudioQueueBufferRef buffers[NUM_BUFFERS];
static AudioFileID audioFileID;

@implementation ViewController

void AudioOutputCallback(void *inUserData,
                         AudioQueueRef outAQ,
                         AudioQueueBufferRef outBuffer
                         ) {
    
    ViewController *viewController = (__bridge ViewController*)inUserData;
    
    if (viewController.currentState != AudioQueueState_Playing) {
        return;
    }
    //set number of bytes should agree with buffer size
    UInt32 numBytes = 16000;
    //involk reading audio file method at the currentByte and load some data into the buffer
    OSStatus status = AudioFileReadBytes(audioFileID, false, currentByte, &numBytes, outBuffer->mAudioData);
    
    if (status != noErr && status != kAudioFileEndOfFileError) {
        printf("Error\n");
        return;
    }
    //if the buffer has read some data, then we tell the queue the buffer is ready
    if (numBytes > 0) {
        outBuffer->mAudioDataByteSize = numBytes;
        //enqueue the filled buffer to the back of the filled buffered queue on the audio queue
        OSStatus statusOfEnqueue = AudioQueueEnqueueBuffer(queue, outBuffer, 0, NULL);
        if (statusOfEnqueue != noErr) {
            printf("Error\n");
            return;
        }
        //move the current position where the buffers had last read something
        currentByte += numBytes;
    }
    
    //end of the audio file - as the callback is involved as a part of audioQueueStart, the callback ends the queue and cleans up when it detects end of file.
    if (numBytes == 0 || status == kAudioFileEndOfFileError) {
        AudioQueueStop(queue,false);
        AudioFileClose(audioFileID);
        viewController.currentState = AudioQueueState_Idle;
    }
    
}

//recording call back function
void AudioInputCallback(
                        void *inUserData,
                        AudioQueueRef inAQ,
                        AudioQueueBufferRef inBuffer,
                        const AudioTimeStamp *inStartTime,
                        UInt32 inNumberPacketDescriptions,
                        const AudioStreamPacketDescription *inPacketDescs
                        ) {
    ViewController *viewController = (__bridge ViewController*)inUserData;
    
    //if not recording, then return immediately
    if (viewController.currentState != AudioQueueState_Recording) {
        return;
    }
    //before write buffer to the file, set number of bytes to write to the file
    UInt32 ioBytes = audioFormat.mBytesPerPacket * inNumberPacketDescriptions;
    //write the the audio file with the buffer mAudioData which is a part of the buffer, currentBytes is the starting point for the file writing, ioBytes is the bytes to be written in this one method call to writeBytes.
    OSStatus status = AudioFileWriteBytes(audioFileID, false, currentByte, &ioBytes, inBuffer->mAudioData);
    
    if (status != noErr) {
        printf("Error");
        return;
    }
    //set currentBytes for the next writeBytes call to the correct position
    currentByte += ioBytes;
    //enqueue the buffer to the buffer queue
    status = AudioQueueEnqueueBuffer(queue, inBuffer, 0, NULL);
    
    printf("Here\n");
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view, typically from a nib.
    [self setupAudio];
}


//audio setup setting audio format object.
- (void) setupAudio {
    audioFormat.mSampleRate = 44100.00;
    audioFormat.mFormatID = kAudioFormatLinearPCM;
    audioFormat.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    audioFormat.mFramesPerPacket = 1;
    audioFormat.mChannelsPerFrame = 1;
    audioFormat.mBitsPerChannel = 16;
    audioFormat.mBytesPerFrame = audioFormat.mChannelsPerFrame * sizeof(SInt16);
    audioFormat.mBytesPerPacket = audioFormat.mFramesPerPacket * audioFormat.mBytesPerFrame;
    
    self.currentState = AudioQueueState_Idle;
}

- (void) stopRecording {
    self.currentState = AudioQueueState_Idle;
    
    AudioQueueStop(queue, true);
    
    for (int i = 0; i < NUM_BUFFERS; i++) {
        AudioQueueFreeBuffer(queue, buffers[i]);
    }
    
    AudioQueueDispose(queue, true);
    AudioFileClose(audioFileID);
}

- (IBAction)recordButtonPressed:(id)sender {
    switch (self.currentState) {
        case AudioQueueState_Idle:
            break;
        case AudioQueueState_Playing:
            //don't want to interrupt
            return;
        case AudioQueueState_Recording:
            //stop recording
            [self stopRecording];
            return;
        default:
            break;
    }
    
    //now we should start recording and first initialize the recorder
    NSError *error;
    [[AVAudioSession sharedInstance] setActive:YES error:&error];
    NSAssert(error == nil, @"Error");
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryRecord error:&error];
    NSAssert(error == nil, @"Error");
    
    [[AVAudioSession sharedInstance] requestRecordPermission:^(BOOL granted) {
        //make sure it has access to mic
        if (granted) {
            
            //start recording...
            self.currentState = AudioQueueState_Recording;
            //set current bytes to 0.
            currentByte = 0;
            
            OSStatus status;
            
            //to create the new audio queue and save it in queue take callback function has one of the parameters, self is the view controller.
            status = AudioQueueNewInput(&audioFormat, AudioInputCallback, (__bridge void*)self, CFRunLoopGetCurrent(), kCFRunLoopCommonModes, 0, &queue);
            
            NSAssert(status == noErr, @"Error");
            
            //allocating buffers ahead of recording
            for (int i = 0; i < NUM_BUFFERS; i++)
            {
                //create and allocate each buffer for this audio queue
                status = AudioQueueAllocateBuffer(queue, 16000, &buffers[i]);
                NSAssert(status == noErr, @"Error");
                //enqueue each buffer to the queue
                status = AudioQueueEnqueueBuffer(queue, buffers[i], 0, NULL);
                NSAssert(status == noErr, @"Error");
            }
            
            //file to write the data to
            NSString *directoryName = NSTemporaryDirectory();
            NSString *fileName = [directoryName stringByAppendingPathComponent:@"audioQueueFile.wav"];
            //NSURL object of the file path
            self.audioFileURL = [NSURL URLWithString:fileName];
            //Create the actual file at that URL - audioFileID object returned, erase if the file already exist
            status = AudioFileCreateWithURL((__bridge CFURLRef)self.audioFileURL, kAudioFileWAVEType, &audioFormat, kAudioFileFlags_EraseFile, &audioFileID);
            NSAssert(status == noErr, @"Error");

            //start the recording...does ALL of the following under the hood...
            //1. Fill the closest buffer with recorded data, once full, call back is involked with this buffer and a bunch of other arguments all of which are automatically supplied and done inside the AudioQueueStart call.
            //2. The callback
                    //1. writes to the file the data from buffer
                    //2. set position in file to where the writing ended so the nex call back knows where to start to write
                    //3. enqueue the buffer to the back of the buffer queue.
            //repeat steps 1 and 2 until stop is called.
            
            status = AudioQueueStart(queue, NULL);
            
            NSAssert(status == noErr, @"Error");
            
        } else {
            //crash if no mic access is granted
            NSAssert(NO, @"Error");
        }
    }];
}

- (void) stopPlayback {
    self.currentState = AudioQueueState_Idle;
    
    for (int i = 0; i < NUM_BUFFERS; i++) {
        AudioQueueFreeBuffer(queue, buffers[i]);
    }
    
    AudioQueueDispose(queue, true);
    AudioFileClose(audioFileID);
}

- (IBAction)playButtonPressed:(id)sender {
    switch (self.currentState) {
        case AudioQueueState_Idle:
            break;
        case AudioQueueState_Playing:
            [self stopPlayback];
            return;
        case AudioQueueState_Recording:
            [self stopRecording];
            break;
        default:
            break;
    }
    
    
    //now we start to play the file...first initialize...
    NSError *error;
    [[AVAudioSession sharedInstance] setActive:YES error:&error];
    NSAssert(error == nil, @"Error");
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:&error];
    NSAssert(error == nil, @"Error");
    //tell the viewController to start playback
    [self startPlayback];
}

- (void) startPlayback {
    
    //store the position of the playback, starting with 0
    currentByte = 0;
    
    //open the Audio file that was recorded earlier
    OSStatus status = AudioFileOpenURL((__bridge CFURLRef) (self.audioFileURL), kAudioFileReadPermission, kAudioFileWAVEType, &audioFileID);
    NSAssert(status == noErr,@"Error");
    
    //making a new audio queue object with an output call back
    status = AudioQueueNewOutput(&audioFormat, AudioOutputCallback,
                                 (__bridge void*)self
                                 , CFRunLoopGetCurrent(), kCFRunLoopCommonModes, 0, &queue);
    NSAssert(status == noErr,@"Error");
    //set state to playing;
    self.currentState = AudioQueueState_Playing;
    
    //loop through the buffers to allocate and playback on the queue
    for (int i = 0; i < NUM_BUFFERS && self.currentState == AudioQueueState_Playing; i++) {
        //allocate each buffer
        status = AudioQueueAllocateBuffer(queue, 16000, &buffers[i]);
        NSAssert(status == noErr,@"Error");
        //involk the callback function on the controller, audio queue and this buffer, this will fill the buffers with audio data and send them to the queue, before starting the queue. This is preparation stage before the queue can enter into a steady state of cycles.
        AudioOutputCallback((__bridge void*)self,queue,buffers[i]);
    }
    //start the queue and at this point audio should start playing immediately from the buffers and the steady state of buffer cycles managed by the audio queue and callback function should start.
    NSLog(@"Music starts now!");
    //Queue starts to play the buffer data and enters into a steady state.
    status = AudioQueueStart(queue, NULL);
    NSAssert(status == noErr,@"Error");
    
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

@end
