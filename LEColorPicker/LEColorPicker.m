//
//  LEColorPicker.m
//  LEColorPicker
//
//  Created by Luis Enrique Espinoza Severino on 10-12-12.
//  Copyright (c) 2012 Luis Espinoza. All rights reserved.
//

#if ! __has_feature(objc_arc)
#warning This file must be compiled with ARC. Use -fobjc-arc flag (or convert project to ARC).
#endif

#import "LEColorPicker.h"
#import "UIColor+YUVSpace.h"
#import "UIColor+ColorScheme.h"
#import <OpenGLES/ES2/gl.h>
#import <OpenGLES/ES2/glext.h>

@implementation LEColorScheme
@end

@implementation LEColorPicker

#pragma mark - Preprocessor definitions
#define LECOLORPICKER_GPU_DEFAULT_SCALED_SIZE                           32
#define LECOLORPICKER_BACKGROUND_FILTER_TOLERANCE                       0.6
#define LECOLORPICKER_PRIMARY_TEXT_FILTER_TOLERANCE                     0.3
#define LECOLORPICKER_DEFAULT_COLOR_DIFFERENCE                          0.05
#define LECOLORPICKER_DEFAULT_COLOR_COMPENSATION                        0.6

#define STRINGIZE(x) #x
#define STRINGIZE2(x) STRINGIZE(x)
#define SHADER_STRING(text) @ STRINGIZE2(text)


#pragma mark - C structures and constants
// Vertex structure
typedef struct {
    float Position[3];
    float Color[4];
    float TexCoord[2];
} Vertex;

// LEColor structure
typedef struct {
    unsigned int red;
    unsigned int green;
    unsigned int blue;
} LEColor;

// Add texture coordinates to Vertices as follows
const Vertex Vertices[] = {
    // Front
    {{1, -1, 0}, {1, 0, 0, 1}, {1, 0}},
    {{1, 1, 0}, {0, 1, 0, 1}, {1, 1}},
    {{-1, 1, 0}, {0, 0, 1, 1}, {0, 1}},
    {{-1, -1, 0}, {0, 0, 0, 1}, {0, 0}},
};

// Triangles coordinates
const GLubyte Indices[] = {
    // Front
    0, 1, 2,
    2, 3, 0,
};

#pragma mark - Dominant finding shaders
NSString *const kDominantVertexShaderString = SHADER_STRING
(
 attribute vec4 Position;
 attribute vec4 SourceColor;
 
 varying vec4 DestinationColor;
 
 attribute vec2 TexCoordIn;
 varying vec2 TexCoordOut;
 
 void main(void) {
     DestinationColor = SourceColor;
     gl_Position = Position;
     TexCoordOut = TexCoordIn;
 }
 );

NSString *const kDominantFragmentShaderString = SHADER_STRING
(
 varying lowp vec4 DestinationColor;
 varying lowp vec2 TexCoordOut;
 uniform sampler2D Texture;
 uniform int ProccesedWidth;
 uniform int TotalWidth;
 
 void main(void) {
     lowp vec4 dummyColor = DestinationColor; //Dummy line for avoid WARNING from shader compiler
     lowp float accumulator = 0.0;
     lowp vec4 currentPixel = texture2D(Texture, TexCoordOut);
     highp float currentY = 0.299*currentPixel.r + 0.587*currentPixel.g+ 0.114*currentPixel.b;
     highp float currentU = (-0.14713)*currentPixel.r + (-0.28886)*currentPixel.g + (0.436)*currentPixel.b;
     highp float currentV = 0.615*currentPixel.r + (-0.51499)*currentPixel.g + (-0.10001)*currentPixel.b;
     highp vec3 currentYUV = vec3(currentY,currentU,currentV);
     lowp float d;
     if ((TexCoordOut.x > (float(ProccesedWidth)/float(TotalWidth))) || (TexCoordOut.y > (float(ProccesedWidth)/float(TotalWidth)))) {
         gl_FragColor = vec4(0.0,0.0,0.0,1.0);
     } else {
         accumulator = 0.0;
         for (int i=0; i<ProccesedWidth; i=i+1) {
             for (int j=0; j<ProccesedWidth; j=j+1) {
                 lowp vec2 coord = vec2(float(i)/float(TotalWidth),float(j)/float(TotalWidth));
                 lowp vec4 samplePixel = texture2D(Texture, coord);
                 
                 highp float sampleY = 0.299*samplePixel.r + 0.587*samplePixel.g+ 0.114*samplePixel.b;
                 highp float sampleU = (-0.14713)*samplePixel.r + (-0.28886)*samplePixel.g + (0.436)*samplePixel.b;
                 highp float sampleV = 0.615*samplePixel.r + (-0.51499)*samplePixel.g + (-0.10001)*samplePixel.b;
                 highp vec3 sampleYUV = vec3(sampleY,sampleU,sampleV);
                 
                 d = distance(sampleYUV,currentYUV);
                 
                 if (d < 0.1) {
                     accumulator = accumulator + 0.0039;
                 }
             }
         }
         gl_FragColor = vec4(currentPixel.r,currentPixel.g,currentPixel.b,accumulator);
     }
 }
 );


#pragma mark - C internal functions declaration (to avoid possible warnings)
/**
 Function for free output buffer data.
 **/
void freeImageData(void *info, const void *data, size_t size);

/**
 Function for calculating the square euclidian distance between 2 RGB colors in RGB space.
 @param colorA A RGB color.
 @param colorB Another RGB color.
 @return The square of euclidian distance in RGB space.
 */
unsigned int squareDistanceInRGBSpaceBetweenColor(LEColor colorA, LEColor colorB);

#pragma mark - C internal functions implementation
void freeImageData(void *info, const void *data, size_t size)
{
    //printf("freeImageData called");
    free((void*)data);
}

unsigned int squareDistanceInRGBSpaceBetweenColor(LEColor colorA, LEColor colorB)
{
    NSUInteger squareDistance = ((colorA.red - colorB.red)*(colorA.red - colorB.red))+
    ((colorA.green - colorB.green) * (colorA.green - colorB.green))+
    ((colorA.blue - colorB.blue) * (colorA.blue - colorB.blue));
    return squareDistance;
}

#pragma mark - Obj-C interface methods

- (id)init
{
    self = [super init];
    if (self) {
        // Create queue and set working flag initial state
        taskQueue = dispatch_queue_create("LEColorPickerQueue", DISPATCH_QUEUE_SERIAL);
        _isWorking = NO;
        
        // Add notifications for multitasking and background aware
        [self addNotificationObservers];
    }
    return self;
}


- (void)pickColorsFromImage:(UIImage *)image
                 onComplete:(void (^)(LEColorScheme *colorsPickedDictionary))completeBlock
{
    if (!_isWorking && [self isAppActive]) {
        dispatch_async(taskQueue, ^{
            // Color calculation process
            _isWorking = YES;
            LEColorScheme *colorScheme = [self colorSchemeFromImage:image];
            
            // Call complete block and pass colors result
            dispatch_async(dispatch_get_main_queue(), ^{
                completeBlock(colorScheme);
            });
            _isWorking = NO;
        });
    }
}

- (LEColorScheme*)colorSchemeFromImage:(UIImage*)inputImage
{
    if ([self isAppActive]) {
        // First, we scale the input image, to get a constant image size and square texture.
        UIImage *scaledImage = [self scaleImage:inputImage
                                          width:LECOLORPICKER_GPU_DEFAULT_SCALED_SIZE
                                         height:LECOLORPICKER_GPU_DEFAULT_SCALED_SIZE];
        
        // Now, We set the initial OpenGL ES 2.0 state.
        [self setupOpenGL];
        
        // Then we set the scaled image as the texture to render.
        _aTexture = [self setupTextureFromImage:scaledImage];
        
        // Now that all is ready, proceed we the render, to find the dominant color
        [self renderDominant];
        
        // Now that we have the rendered result, we start the color calculations.
        LEColorScheme *colorScheme = [[LEColorScheme alloc] init];
        colorScheme.backgroundColor = [self colorWithBiggerCountFromImageWidth:LECOLORPICKER_GPU_DEFAULT_SCALED_SIZE height:LECOLORPICKER_GPU_DEFAULT_SCALED_SIZE];
        
        NSArray *textColorAndHarmonics = [self getTextColorsAndHarmonicsFromImage:scaledImage backgroundColor:colorScheme.backgroundColor];
        colorScheme.primaryTextColor = textColorAndHarmonics[1];
        colorScheme.secondaryTextColor = textColorAndHarmonics[2];
        colorScheme.colorScheme = textColorAndHarmonics[0];
        
        // Final fix
        [self fixColorSchemeReadability:colorScheme];
        
        return colorScheme;
    }
    
    return nil;
}

#pragma mark - Old interface implementation
+ (void)pickColorFromImage:(UIImage *)image onComplete:(void (^)(NSDictionary *))completeBlock
{
    LEColorPicker *colorPicker = [[LEColorPicker alloc] init];
    [colorPicker pickColorsFromImage:image onComplete:^(LEColorScheme *colorScheme) {
        NSDictionary *colorsDictionary = [NSDictionary dictionaryWithObjectsAndKeys:
                                          colorScheme.backgroundColor,@"BackgroundColor",
                                          colorScheme.primaryTextColor,@"PrimaryTextColor",
                                          colorScheme.secondaryTextColor,@"SecondaryTextColor", nil];
        completeBlock(colorsDictionary);
    }];
}

#pragma mark - OpenGL ES 2 custom methods

- (void)setupOpenGL
{
    // Start openGLES
    
    [self setupContext];
    
    [self setupFrameBuffer];
    
    [self setupRenderBuffer];
    
    [self setupDepthBuffer];
    
    [self setupOpenGLForDominantColor];
    
    [self setupVBOs];
}

- (void)renderDominant
{
    //start up
    glEnable(GL_BLEND);
    glBlendFunc(GL_ONE, GL_ZERO);
    glEnable(GL_TEXTURE_2D);
    
    //Setup inputs
    glViewport(0, 0, LECOLORPICKER_GPU_DEFAULT_SCALED_SIZE, LECOLORPICKER_GPU_DEFAULT_SCALED_SIZE);
    glBindBuffer(GL_ARRAY_BUFFER, _vertexBuffer);
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, _indexBuffer);
    glVertexAttribPointer(_positionSlot, 3, GL_FLOAT, GL_FALSE, sizeof(Vertex), 0);
    glVertexAttribPointer(_colorSlot, 4, GL_FLOAT, GL_FALSE, sizeof(Vertex), (GLvoid*) (sizeof(float) * 3));
    
    glVertexAttribPointer(_texCoordSlot, 2, GL_FLOAT, GL_FALSE, sizeof(Vertex), (GLvoid*) (sizeof(float) * 7));
    
    glUniform1i(_proccesedWidthSlot, LECOLORPICKER_GPU_DEFAULT_SCALED_SIZE/2);
    glUniform1i(_totalWidthSlot, LECOLORPICKER_GPU_DEFAULT_SCALED_SIZE);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, _aTexture);
    glUniform1i(_textureUniform, 0);
    glDrawElements(GL_TRIANGLES, sizeof(Indices)/sizeof(Indices[0]), GL_UNSIGNED_BYTE, 0);
}

- (GLuint)setupTextureFromImage:(UIImage*)image
{
    // Get core graphics image reference
    CGImageRef inputTextureImage = image.CGImage;
    
    if (!inputTextureImage) {
        LELog(@"Failed to load image for texture");
        exit(1);
    }
    
    size_t width = CGImageGetWidth(inputTextureImage);
    size_t height = CGImageGetHeight(inputTextureImage);
    
    GLubyte *inputTextureData = (GLubyte*)calloc(width*height*4, sizeof(GLubyte));
    CGColorSpaceRef inputTextureColorSpace = CGImageGetColorSpace(inputTextureImage);
    CGContextRef inputTextureContext = CGBitmapContextCreate(inputTextureData, width, height, 8, width*4, inputTextureColorSpace , kCGImageAlphaPremultipliedLast);
    //3 Draw image into the context
    CGContextDrawImage(inputTextureContext, CGRectMake(0, 0, width, height),inputTextureImage);
    CGContextRelease(inputTextureContext);
    
    
    //4 Send the pixel data to OpenGL
    GLuint inputTexName;
    glGenTextures(1, &inputTexName);
    glBindTexture(GL_TEXTURE_2D, inputTexName);
    
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexImage2D(GL_TEXTURE_2D, 0,GL_RGBA , width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, inputTextureData);
    free(inputTextureData);
    return inputTexName;
}

- (void)setupContext {
    EAGLRenderingAPI api = kEAGLRenderingAPIOpenGLES2;
    _context = [[EAGLContext alloc] initWithAPI:api];
    if (!_context) {
        //NSLog(@"Failed to initialize OpenGLES 2.0 context");
        exit(1);
    }
    
    if (![EAGLContext setCurrentContext:_context]) {
        //NSLog(@"Failed to set current OpenGL context");
        exit(1);
    }
}

- (void)setupFrameBuffer {
    GLuint framebuffer;
    glGenFramebuffers(1, &framebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
}


- (void)setupRenderBuffer {
    glGenRenderbuffers(1, &_colorRenderBuffer);
    glBindRenderbuffer(GL_RENDERBUFFER, _colorRenderBuffer);
    glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8_OES, LECOLORPICKER_GPU_DEFAULT_SCALED_SIZE, LECOLORPICKER_GPU_DEFAULT_SCALED_SIZE);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, _colorRenderBuffer);
}

- (void)setupDepthBuffer {
    glGenRenderbuffers(1, &_depthRenderBuffer);
    glBindRenderbuffer(GL_RENDERBUFFER, _depthRenderBuffer);
    glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT16, LECOLORPICKER_GPU_DEFAULT_SCALED_SIZE , LECOLORPICKER_GPU_DEFAULT_SCALED_SIZE);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, _depthRenderBuffer);
}


- (void)setupVBOs {
    
    glGenBuffers(1, &_vertexBuffer);
    glBindBuffer(GL_ARRAY_BUFFER, _vertexBuffer);
    glBufferData(GL_ARRAY_BUFFER, sizeof(Vertices), Vertices, GL_STATIC_DRAW);
    
    glGenBuffers(1, &_indexBuffer);
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, _indexBuffer);
    glBufferData(GL_ELEMENT_ARRAY_BUFFER, sizeof(Indices), Indices, GL_STATIC_DRAW);
}

- (BOOL)setupOpenGLForDominantColor
{
    GLuint vertShader, fragShader;
    
    // Create and compile vertex shader.
    if (![self compileShader:&vertShader type:GL_VERTEX_SHADER string:kDominantVertexShaderString]) {
        LELog(@"Failed to compile vertex shader");
        return NO;
    }
    
    // Create and compile fragment shader.
    if (![self compileShader:&fragShader type:GL_FRAGMENT_SHADER string:kDominantFragmentShaderString]) {
        LELog(@"Failed to compile fragment shader");
        return NO;
    }
    
    // Create shader program.
    _program = glCreateProgram();
    
    // Attach vertex shader to program.
    glAttachShader(_program, vertShader);
    
    // Attach fragment shader to program.
    glAttachShader(_program, fragShader);
    
    // Link program.
    if (![self linkProgram:_program]) {
        LELog(@"Failed to link program: %d", _program);
        
        if (vertShader) {
            glDeleteShader(vertShader);
            vertShader = 0;
        }
        if (fragShader) {
            glDeleteShader(fragShader);
            fragShader = 0;
        }
        if (_program) {
            glDeleteProgram(_program);
            _program = 0;
        }
        return NO;
    }
    
    glUseProgram(_program);
    
    //Get attributes locations
    _positionSlot = glGetAttribLocation(_program, "Position");
    _colorSlot = glGetAttribLocation(_program, "SourceColor");
    _texCoordSlot = glGetAttribLocation(_program, "TexCoordIn");
    glEnableVertexAttribArray(_positionSlot);
    glEnableVertexAttribArray(_colorSlot);
    glEnableVertexAttribArray(_texCoordSlot);
    
    _textureUniform = glGetUniformLocation(_program, "Texture");
    _proccesedWidthSlot = glGetUniformLocation(_program, "ProccesedWidth");
    _totalWidthSlot = glGetUniformLocation(_program, "TotalWidth");
    return YES;
}



#pragma mark -  OpenGL ES 2 shader compilation

- (BOOL)compileShader:(GLuint *)shader type:(GLenum)type string:(NSString *)string
{
    GLint status;
    const GLchar *source;
    
    source = (GLchar *)[string UTF8String];
    if (!source) {
        LELog(@"Failed to load vertex shader");
        return NO;
    }
    
    *shader = glCreateShader(type);
    glShaderSource(*shader, 1, &source, NULL);
    glCompileShader(*shader);
    
#ifdef LE_DEBUG
    GLint logLength;
    glGetShaderiv(*shader, GL_INFO_LOG_LENGTH, &logLength);
    if (logLength > 0) {
        GLchar *log = (GLchar *)malloc(logLength);
        glGetShaderInfoLog(*shader, logLength, &logLength, log);
        NSLog(@"Shader compile log:\n%s", log);
        free(log);
    }
#endif
    
    glGetShaderiv(*shader, GL_COMPILE_STATUS, &status);
    if (status == 0) {
        glDeleteShader(*shader);
        return NO;
    }
    
    return YES;
}

- (BOOL)linkProgram:(GLuint)prog
{
    GLint status;
    glLinkProgram(prog);
    
#ifdef LE_DEBUG
    GLint logLength;
    glGetProgramiv(prog, GL_INFO_LOG_LENGTH, &logLength);
    if (logLength > 0) {
        GLchar *log = (GLchar *)malloc(logLength);
        glGetProgramInfoLog(prog, logLength, &logLength, log);
        NSLog(@"Program link log:\n%s", log);
        free(log);
    }
#endif
    
    glGetProgramiv(prog, GL_LINK_STATUS, &status);
    if (status == 0) {
        return NO;
    }
    
    return YES;
}

- (BOOL)validateProgram:(GLuint)prog
{
    GLint logLength, status;
    
    glValidateProgram(prog);
    glGetProgramiv(prog, GL_INFO_LOG_LENGTH, &logLength);
    if (logLength > 0) {
        GLchar *log = (GLchar *)malloc(logLength);
        glGetProgramInfoLog(prog, logLength, &logLength, log);
        LELog(@"Program validate log:\n%s", log);
        free(log);
    }
    
    glGetProgramiv(prog, GL_VALIDATE_STATUS, &status);
    if (status == 0) {
        return NO;
    }
    
    return YES;
}


#pragma mark - Convert GL image to UIImage
-(UIImage *)dumpImageWithWidth:(NSUInteger)width height:(NSUInteger)height
{
    GLubyte *buffer = (GLubyte *) malloc(width * height * 4);
    glReadPixels(0, 0, width, height, GL_RGBA, GL_UNSIGNED_BYTE, (GLvoid *)buffer);
    
    NSUInteger biggerR = 0;
    NSUInteger biggerG = 0;
    NSUInteger biggerB = 0;
    NSUInteger biggerAlpha = 0;
    
    for (NSUInteger y=0; y<(height/2); y++) {
        for (NSUInteger x=0; x<(width/2)*4; x++) {
            //buffer2[y * 4 * width + x] = buffer[(height - y - 1) * width * 4 + x];
            //NSLog(@"x=%d y=%d pixel=%d",x/4,y,buffer[y * 4 * width + x]);
            if ((!((x+1)%4)) && (x>0)) {
                if (buffer[y * 4 * width + x] > biggerAlpha ) {
                    
                    biggerAlpha = buffer[y * 4 * width + x];
                    biggerR = buffer[y * 4 * width + (x-3)];
                    biggerG = buffer[y * 4 * width + (x-2)];
                    biggerB = buffer[y * 4 * width + (x-1)];
                    //        NSLog(@"biggerR=%d biggerG=%d biggerB=%d biggerAlpha=%d",biggerR,biggerG,biggerB,biggerAlpha);
                }
            }
        }
    }
    
    // make data provider from buffer
    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, buffer, width * height * 4, freeImageData);
    
    // set up for CGImage creation
    int bitsPerComponent = 8;
    int bitsPerPixel = 32;
    int bytesPerRow = 4 * width;
    CGColorSpaceRef colorSpaceRef = CGColorSpaceCreateDeviceRGB();
    CGBitmapInfo bitmapInfo = kCGImageAlphaPremultipliedLast | kCGBitmapByteOrderDefault;
    // Use this to retain alpha
    CGColorRenderingIntent renderingIntent = kCGRenderingIntentDefault;
    CGImageRef imageRef = CGImageCreate(width, height, bitsPerComponent, bitsPerPixel, bytesPerRow, colorSpaceRef, bitmapInfo, provider, NULL, NO, renderingIntent);
    
    // make UIImage from CGImage
    UIImage *newUIImage = [UIImage imageWithCGImage:imageRef];
    CGImageRelease(imageRef);
    CGColorSpaceRelease(colorSpaceRef);
    
    return newUIImage;
}

#pragma mark - Image look-ups

-(UIColor *)colorWithBiggerCountFromImageWidth:(NSUInteger)width height:(NSUInteger)height
{
    GLubyte *buffer = (GLubyte *) malloc(width * height * 4);
    glReadPixels(0, 0, width, height, GL_RGBA, GL_UNSIGNED_BYTE, (GLvoid *)buffer);
    
    /* Find bigger Alpha color*/
    NSUInteger biggerR = 0;
    NSUInteger biggerG = 0;
    NSUInteger biggerB = 0;
    NSUInteger biggerAlpha = 0;
    
    for (NSUInteger y=0; y<(height/2); y++) {
        for (NSUInteger x=0; x<(width/2)*4; x++) {
            if ((!((x+1)%4)) && (x>0)) {
                if (buffer[y * 4 * width + x] > biggerAlpha ) {
                    biggerAlpha = buffer[y * 4 * width + x];
                    biggerR = buffer[y * 4 * width + (x-3)];
                    biggerG = buffer[y * 4 * width + (x-2)];
                    biggerB = buffer[y * 4 * width + (x-1)];
                }
            }
        }
    }
    
    free(buffer);
    
    return [UIColor colorWithRed:biggerR/255.0
                           green:biggerG/255.0
                            blue:biggerB/255.0
                           alpha:1.0];
}

- (NSArray*)getTextColorsAndHarmonicsFromImage:(UIImage*)inputImage backgroundColor:inputBackgroundColor
{
    
    //The return
    NSMutableArray *retArray = [[NSMutableArray alloc] initWithCapacity:3];
    
    //Get Pixel Array from the inputImage.
    CGFloat count = inputImage.size.width * inputImage.size.height;
    NSArray *pixelArray = [self getRGBAsFromImage:inputImage atX:0 andY:0 count:count];
    
    //Prapare control color
    UIColor *primaryControlColor;
    UIColor *secondaryControlColor;
    
    NSArray *hsbColor = [inputBackgroundColor hsbaArray];
    float hue = [hsbColor[0] floatValue] * 360;
    float brightness = [hsbColor[2] floatValue];
    float roundedHue = (roundf(hue/30.0)*30)/360;
    
    NSArray *colorSchemeArray = [NSArray array]; //Just in case... 
    
    if (brightness < 0.2) {
        UIColor *color = [UIColor colorWithHue:roundedHue saturation:1 brightness:1 alpha:1.0];
        colorSchemeArray = [color colorSchemeOfType:ColorSchemeAnalagous];
        primaryControlColor = colorSchemeArray[3];
        secondaryControlColor = colorSchemeArray[0];
        [retArray addObject:colorSchemeArray];
    } else if (brightness > 0.8) {
        UIColor *color = [UIColor colorWithHue:roundedHue saturation:1 brightness:0.2 alpha:1.0];
        colorSchemeArray = [color colorSchemeOfType:ColorSchemeAnalagous];
        primaryControlColor = colorSchemeArray[3];
        secondaryControlColor = colorSchemeArray[0];
        [retArray addObject:colorSchemeArray];
    } else {
        UIColor *color = [UIColor colorWithHue:roundedHue saturation:1 brightness:1 alpha:1.0];
        colorSchemeArray = [color colorSchemeOfType:ColorSchemeSplitComplements];
        primaryControlColor = colorSchemeArray[3];
        secondaryControlColor = colorSchemeArray[0];
        [retArray addObject:colorSchemeArray];
    }
    
    //Look up for the closest to the controlColor inside the pixelArray
    //Initial parameters
    float primaryLastDistance = 1;
    float secondaryLastDistance = 1;
    UIColor *primaryColor = primaryControlColor;
    UIColor *secondaryColor = secondaryControlColor;
    
    if ([pixelArray count]) {
        for (NSUInteger i = 0; i < [pixelArray count]; i++) {
            
            UIColor *pixelColor = [pixelArray objectAtIndex:i];
            
            float primaryDistance = [UIColor YUVSpaceSquareDistanceToColor:pixelColor fromColor:primaryControlColor];
            if (primaryDistance < primaryLastDistance) {
                primaryLastDistance = primaryDistance;
                primaryColor = pixelColor;
            }
            
            float secondaryDistance = [UIColor YUVSpaceSquareDistanceToColor:pixelColor fromColor:secondaryControlColor];
            if (secondaryDistance < secondaryLastDistance) {
                secondaryLastDistance = secondaryDistance;
                secondaryColor = pixelColor;
            }
        }
    }
    
    [retArray addObject:primaryColor];
    [retArray addObject:secondaryColor];
    
    return retArray;
}

- (void)fixColorSchemeReadability:(LEColorScheme*)colorScheme
{
    NSArray *backgroundHSBArray = [colorScheme.backgroundColor hsbaArray];
    float backgroundBrightness = [backgroundHSBArray[2] floatValue];
    float backgoundHue = [backgroundHSBArray[0] floatValue];
    
    NSArray *primaryHSBArray = [colorScheme.primaryTextColor hsbaArray];
    float primaryHue = [primaryHSBArray[0] floatValue];
    float primarySat = [primaryHSBArray[1] floatValue];
    float primaryBrightness = [primaryHSBArray[2] floatValue];
    
    NSArray *secondaryHSBArray = [colorScheme.secondaryTextColor hsbaArray];
    float secondaryHue = [secondaryHSBArray[0] floatValue];
    float secondarySat = [secondaryHSBArray[1] floatValue];
    float secondaryBrightness = [secondaryHSBArray[2] floatValue];
    
    float difference = 0;
    float compensation = 0;
    
    if (backgroundBrightness < LECOLORPICKER_BACKGROUND_FILTER_TOLERANCE) {
        difference = fabs(primaryBrightness-backgroundBrightness);
        if (difference < LECOLORPICKER_BACKGROUND_FILTER_TOLERANCE) {
            if (fabs(backgoundHue-primaryHue) < LECOLORPICKER_DEFAULT_COLOR_DIFFERENCE) {
                compensation = 1;
                primarySat = 0.25;
            } else {
                compensation = (backgroundBrightness+LECOLORPICKER_DEFAULT_COLOR_COMPENSATION);
            }
            colorScheme.primaryTextColor = [UIColor colorWithHue:primaryHue saturation:primarySat brightness:fminf(compensation, 1.) alpha:1.0];
        }
        difference = fabs(secondaryBrightness-backgroundBrightness);
        if (difference < LECOLORPICKER_BACKGROUND_FILTER_TOLERANCE) {float compensation = 0;
            if (fabs(backgoundHue-secondaryHue) < LECOLORPICKER_DEFAULT_COLOR_DIFFERENCE) {
                compensation = 1;
                secondarySat = 0.25;
            } else {
                compensation = (backgroundBrightness+LECOLORPICKER_DEFAULT_COLOR_COMPENSATION);
            }
            colorScheme.secondaryTextColor = [UIColor colorWithHue:secondaryHue saturation:secondarySat brightness:fminf(compensation, 1.) alpha:1.0];
        }
    } else {
        difference = fabs(primaryBrightness-backgroundBrightness);
        if (difference < LECOLORPICKER_BACKGROUND_FILTER_TOLERANCE) {
            if (fabs(backgoundHue-primaryHue) < LECOLORPICKER_DEFAULT_COLOR_DIFFERENCE) {
                compensation = 0;
                primarySat = 0.25;
            } else {
                compensation = (backgroundBrightness-LECOLORPICKER_DEFAULT_COLOR_COMPENSATION);
            }
            colorScheme.primaryTextColor = [UIColor colorWithHue:primaryHue saturation:primarySat brightness:fmaxf(compensation, 0.) alpha:1.0];
        }
        difference = fabs(secondaryBrightness-backgroundBrightness);
        if (difference < LECOLORPICKER_BACKGROUND_FILTER_TOLERANCE) {
            if (fabs(backgoundHue-secondaryHue) < LECOLORPICKER_DEFAULT_COLOR_DIFFERENCE) {
                compensation = 0;
                secondarySat = 0.25;
            } else {
                compensation = (backgroundBrightness-LECOLORPICKER_DEFAULT_COLOR_COMPENSATION);
            }
            colorScheme.secondaryTextColor = [UIColor colorWithHue:secondaryHue saturation:secondarySat brightness:fmaxf(compensation,0.) alpha:1.0];
        }
    }
}

#pragma mark - UIImage utilities
- (UIImage*)scaleImage:(UIImage*)image width:(CGFloat)width height:(CGFloat)height
{
    UIImage *scaledImage =  [self imageWithImage:image scaledToSize:CGSizeMake(width,height)];
    return scaledImage;
}

- (UIImage *)imageWithImage:(UIImage *)image scaledToSize:(CGSize)newSize {
    UIGraphicsBeginImageContextWithOptions(newSize, NO, 1.0);
    [image drawInRect:CGRectMake(0, 0, newSize.width, newSize.height)];
    UIImage *newImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return newImage;
}

-  (NSArray*)getRGBAsFromImage:(UIImage*)image atX:(int)xx andY:(int)yy count:(int)count
{
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:count];
    
    // First get the image into your data buffer
    CGImageRef imageRef = [image CGImage];
    NSUInteger width = CGImageGetWidth(imageRef);
    NSUInteger height = CGImageGetHeight(imageRef);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    unsigned char *rawData = (unsigned char*) calloc(height * width * 4, sizeof(unsigned char));
    NSUInteger bytesPerPixel = 4;
    NSUInteger bytesPerRow = bytesPerPixel * width;
    NSUInteger bitsPerComponent = 8;
    CGContextRef context = CGBitmapContextCreate(rawData, width, height,
                                                 bitsPerComponent, bytesPerRow, colorSpace,
                                                 kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(colorSpace);
    
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), imageRef);
    CGContextRelease(context);
    
    // Now your rawData contains the image data in the RGBA8888 pixel format.
    int byteIndex = (bytesPerRow * yy) + xx * bytesPerPixel;
    for (int ii = 0 ; ii < count ; ++ii)
    {
        @autoreleasepool {
            CGFloat red   = (rawData[byteIndex]     * 1.0) / 255.0;
            CGFloat green = (rawData[byteIndex + 1] * 1.0) / 255.0;
            CGFloat blue  = (rawData[byteIndex + 2] * 1.0) / 255.0;
            CGFloat alpha = (rawData[byteIndex + 3] * 1.0) / 255.0;
            byteIndex += 4;
            
            UIColor *acolor = [UIColor colorWithRed:red green:green blue:blue alpha:alpha];
            [result addObject:acolor];
        }
    }
    
    free(rawData);
    
    return result;
}

#pragma mark - Multitasking and Background aware
- (void)addNotificationObservers
{
    // Add observers for notification to respond at app state changes.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appWillResignActive)
                                                 name:UIApplicationWillResignActiveNotification
                                               object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appDidEnterBackground)
                                                 name:UIApplicationDidEnterBackgroundNotification
                                               object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appDidEnterForeground)
                                                 name:UIApplicationWillEnterForegroundNotification
                                               object:nil];
}

- (void)dealloc {
    //Remove all observers
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationWillResignActiveNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidEnterBackgroundNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationWillEnterForegroundNotification object:nil];
}

- (void)appWillResignActive
{
    dispatch_suspend(taskQueue);
    glFinish();
}

- (void)appDidEnterBackground
{
    dispatch_suspend(taskQueue);
    glFinish();
    
}

- (void)appDidEnterForeground
{
    dispatch_resume(taskQueue);
}

- (BOOL)isAppActive
{
    UIApplicationState state = [[UIApplication sharedApplication] applicationState];
    if (state == UIApplicationStateBackground || state == UIApplicationStateInactive)
    {
        return NO;
    }
    
    return YES;
}
@end
