/* Snow Leopard GPU capability probe. No window or system configuration changes. */
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl.h>
#include <OpenGL/glext.h>
#include <stdio.h>
#include <string.h>

static int has_extension(const char *extensions, const char *name)
{
    size_t length = strlen(name);
    const char *p = extensions;
    if (!p) return 0;
    while ((p = strstr(p, name))) {
        if ((p == extensions || p[-1] == ' ') &&
            (p[length] == ' ' || p[length] == '\0')) return 1;
        p += length;
    }
    return 0;
}

static GLuint compile_shader(GLenum kind, const char *source)
{
    GLuint shader = glCreateShader(kind);
    GLint ok = GL_FALSE;
    glShaderSource(shader, 1, &source, NULL);
    glCompileShader(shader);
    glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[4096];
        GLsizei length = 0;
        glGetShaderInfoLog(shader, sizeof(log), &length, log);
        fprintf(stderr, "Shader compile failed: %.*s\n", (int)length, log);
        glDeleteShader(shader);
        return 0;
    }
    return shader;
}

static int render_probe(void)
{
    const char *vertex_source =
        "#version 120\nvoid main() { gl_Position = gl_Vertex; }\n";
    const char *fragment_source =
        "#version 120\nuniform sampler2D atlas;\n"
        "void main() { gl_FragColor = vec4(0.25, 0.5, 0.75, "
        "texture2D(atlas, vec2(0.5)).a); }\n";
    GLuint vertex = compile_shader(GL_VERTEX_SHADER, vertex_source);
    GLuint fragment = compile_shader(GL_FRAGMENT_SHADER, fragment_source);
    GLuint program = 0, target = 0, atlas = 0, framebuffer = 0;
    int result = 1;
    if (!vertex || !fragment) goto cleanup;

    program = glCreateProgram();
    glAttachShader(program, vertex);
    glAttachShader(program, fragment);
    glLinkProgram(program);
    GLint linked = GL_FALSE;
    glGetProgramiv(program, GL_LINK_STATUS, &linked);
    if (!linked) {
        char log[4096];
        GLsizei length = 0;
        glGetProgramInfoLog(program, sizeof(log), &length, log);
        fprintf(stderr, "Shader link failed: %.*s\n", (int)length, log);
        goto cleanup;
    }

    glGenTextures(1, &target);
    glBindTexture(GL_TEXTURE_2D, target);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 16, 16, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    glGenFramebuffersEXT(1, &framebuffer);
    glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, framebuffer);
    glFramebufferTexture2DEXT(GL_FRAMEBUFFER_EXT, GL_COLOR_ATTACHMENT0_EXT,
                             GL_TEXTURE_2D, target, 0);
    GLenum status = glCheckFramebufferStatusEXT(GL_FRAMEBUFFER_EXT);
    if (status != GL_FRAMEBUFFER_COMPLETE_EXT) {
        fprintf(stderr, "Framebuffer incomplete: 0x%x\n", status);
        goto cleanup;
    }

    const GLubyte coverage[4] = { 128, 128, 128, 128 };
    glGenTextures(1, &atlas);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, atlas);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_ALPHA8, 2, 2, 0,
                 GL_ALPHA, GL_UNSIGNED_BYTE, coverage);

    glViewport(0, 0, 16, 16);
    glDrawBuffer(GL_COLOR_ATTACHMENT0_EXT);
    glReadBuffer(GL_COLOR_ATTACHMENT0_EXT);
    glClearColor(0, 0, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT);
    glUseProgram(program);
    glUniform1i(glGetUniformLocation(program, "atlas"), 0);
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    /* Immediate mode is used only to keep this diagnostic small. */
    glBegin(GL_QUADS);
    glVertex2f(-1, -1); glVertex2f(1, -1);
    glVertex2f(1, 1); glVertex2f(-1, 1);
    glEnd();

    GLubyte pixel[4] = { 0 };
    glReadPixels(8, 8, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
    GLenum error = glGetError();
    printf("GLSL 1.20 / A8 glyph coverage / FBO / blending readback: "
           "%u %u %u %u; GL error: 0x%x\n",
           pixel[0], pixel[1], pixel[2], pixel[3], error);
    if (error != GL_NO_ERROR || pixel[0] < 29 || pixel[0] > 35 ||
        pixel[1] < 61 || pixel[1] > 67 || pixel[2] < 93 || pixel[2] > 99) {
        fprintf(stderr, "Render readback does not match expected RGB 32 64 96\n");
        goto cleanup;
    }
    puts("GPU render probe: PASS");
    result = 0;

cleanup:
    glUseProgram(0);
    if (framebuffer) glDeleteFramebuffersEXT(1, &framebuffer);
    if (atlas) glDeleteTextures(1, &atlas);
    if (target) glDeleteTextures(1, &target);
    if (program) glDeleteProgram(program);
    if (fragment) glDeleteShader(fragment);
    if (vertex) glDeleteShader(vertex);
    return result;
}

int main(void)
{
    CGLPixelFormatAttribute attributes[] = {
        kCGLPFAAccelerated, kCGLPFANoRecovery, kCGLPFAColorSize,
        (CGLPixelFormatAttribute)24, (CGLPixelFormatAttribute)0
    };
    CGLPixelFormatObj format = NULL;
    CGLContextObj context = NULL;
    GLint count = 0;
    CGLError error = CGLChoosePixelFormat(attributes, &format, &count);
    if (error != kCGLNoError || !format) {
        fprintf(stderr, "No accelerated pixel format: %s\n", CGLErrorString(error));
        return 1;
    }
    error = CGLCreateContext(format, NULL, &context);
    if (error != kCGLNoError) {
        fprintf(stderr, "Context creation failed: %s\n", CGLErrorString(error));
        CGLDestroyPixelFormat(format);
        return 1;
    }
    error = CGLSetCurrentContext(context);
    if (error != kCGLNoError) {
        fprintf(stderr, "Setting context failed: %s\n", CGLErrorString(error));
        CGLDestroyContext(context);
        CGLDestroyPixelFormat(format);
        return 1;
    }
    GLint accelerated = 0;
    CGLDescribePixelFormat(format, 0, kCGLPFAAccelerated, &accelerated);
    printf("Accelerated pixel format: %d\nVendor: %s\nRenderer: %s\n"
           "OpenGL: %s\nGLSL: %s\n", accelerated,
           glGetString(GL_VENDOR), glGetString(GL_RENDERER),
           glGetString(GL_VERSION), glGetString(GL_SHADING_LANGUAGE_VERSION));
    GLint max_texture = 0, texture_units = 0, vertex_attributes = 0;
    glGetIntegerv(GL_MAX_TEXTURE_SIZE, &max_texture);
    glGetIntegerv(GL_MAX_TEXTURE_IMAGE_UNITS, &texture_units);
    glGetIntegerv(GL_MAX_VERTEX_ATTRIBS, &vertex_attributes);
    printf("Max texture size: %d; fragment texture units: %d; vertex attributes: %d\n",
           max_texture, texture_units, vertex_attributes);
    const char *extensions = (const char *)glGetString(GL_EXTENSIONS);
    const char *names[] = {
        "GL_EXT_framebuffer_object", "GL_ARB_texture_non_power_of_two",
        "GL_EXT_texture_sRGB", "GL_EXT_framebuffer_sRGB",
        "GL_ARB_pixel_buffer_object", "GL_APPLE_vertex_array_object"
    };
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); ++i)
        printf("%s: %s\n", names[i], has_extension(extensions, names[i]) ? "yes" : "no");
    int result = 1;
    if (accelerated && has_extension(extensions, "GL_EXT_framebuffer_object"))
        result = render_probe();
    else
        fprintf(stderr, "Required accelerated renderer/FBO support missing\n");
    CGLSetCurrentContext(NULL);
    CGLDestroyContext(context);
    CGLDestroyPixelFormat(format);
    return result;
}
