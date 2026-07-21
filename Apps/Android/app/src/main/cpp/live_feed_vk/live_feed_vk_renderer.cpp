// Vulkan live-feed presenter: upload RGBA frame + grade with SPIR-V LUT pass.
// Falls back is owned by Kotlin when create/init fails.

#include "live_feed_vk_renderer.h"

#include <android/bitmap.h>
#include <android/log.h>
#include <vulkan/vulkan.h>
#include <vulkan/vulkan_android.h>

#include <algorithm>
#include <atomic>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, "ZCLiveFeedVk", __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, "ZCLiveFeedVk", __VA_ARGS__)

namespace {

constexpr int kMaxFramesInFlight = 2;

struct GpuParams {
    float lutSize;
    float peakingOn;
    float zebraHighlightOn;
    float zebraMidtoneOn;
    float peakingColor[4];
    float zebraHighlightColor[4];
    float zebraMidtoneColor[4];
    float peakingThreshold;
    float peakingRamp;
    float zebraHighlight;
    float zebraMidtone;
    float aspectFill;
    // Peaking de-log curve (5 points) + source extent for dual-scale Sobel.
    float deLogCurve0to3[4];
    float deLogCurve4;
    float sourceSize[2];
    float pad;
};

}  // namespace

// Complete type for the opaque handle declared in the header (must not be anonymous).
struct LiveFeedVkSession {
    std::mutex lock;
    AAssetManager* assets = nullptr;
    ANativeWindow* window = nullptr;
    bool paused = true;
    bool hasFrame = false;
    bool hasPlan = false;
    int surfaceW = 0;
    int surfaceH = 0;

    VkInstance instance = VK_NULL_HANDLE;
    VkPhysicalDevice physical = VK_NULL_HANDLE;
    VkDevice device = VK_NULL_HANDLE;
    VkQueue queue = VK_NULL_HANDLE;
    uint32_t queueFamily = 0;
    VkSurfaceKHR surface = VK_NULL_HANDLE;
    VkSwapchainKHR swapchain = VK_NULL_HANDLE;
    VkFormat swapFormat = VK_FORMAT_R8G8B8A8_UNORM;
    std::vector<VkImage> swapImages;
    std::vector<VkImageView> swapViews;
    std::vector<VkFramebuffer> framebuffers;
    VkRenderPass renderPass = VK_NULL_HANDLE;
    VkPipelineLayout pipelineLayout = VK_NULL_HANDLE;
    VkPipeline pipeline = VK_NULL_HANDLE;
    VkDescriptorSetLayout setLayout = VK_NULL_HANDLE;
    VkDescriptorPool descPool = VK_NULL_HANDLE;
    VkDescriptorSet descSet = VK_NULL_HANDLE;
    VkCommandPool cmdPool = VK_NULL_HANDLE;
    VkCommandBuffer cmd = VK_NULL_HANDLE;
    VkSemaphore imageAvailable = VK_NULL_HANDLE;
    VkSemaphore renderFinished = VK_NULL_HANDLE;
    VkFence inFlight = VK_NULL_HANDLE;

    VkImage feedImage = VK_NULL_HANDLE;
    VkDeviceMemory feedMem = VK_NULL_HANDLE;
    VkImageView feedView = VK_NULL_HANDLE;
    VkSampler sampler = VK_NULL_HANDLE;
    int feedW = 0;
    int feedH = 0;

    VkImage lutImage = VK_NULL_HANDLE;
    VkDeviceMemory lutMem = VK_NULL_HANDLE;
    VkImageView lutView = VK_NULL_HANDLE;
    int lutSize = 0;

    VkBuffer paramsBuffer = VK_NULL_HANDLE;
    VkDeviceMemory paramsMem = VK_NULL_HANDLE;
    GpuParams params{};

    VkBuffer staging = VK_NULL_HANDLE;
    VkDeviceMemory stagingMem = VK_NULL_HANDLE;
    VkDeviceSize stagingSize = 0;

    std::vector<uint8_t> vertSpv;
    std::vector<uint8_t> fragSpv;
};

namespace {

bool loadAsset(AAssetManager* am, const char* path, std::vector<uint8_t>& out) {
    AAsset* asset = AAssetManager_open(am, path, AASSET_MODE_BUFFER);
    if (!asset) return false;
    const size_t len = static_cast<size_t>(AAsset_getLength(asset));
    out.resize(len);
    const int read = AAsset_read(asset, out.data(), len);
    AAsset_close(asset);
    return read == static_cast<int>(len);
}

uint32_t findMemoryType(VkPhysicalDevice phys, uint32_t typeBits, VkMemoryPropertyFlags props) {
    VkPhysicalDeviceMemoryProperties mem{};
    vkGetPhysicalDeviceMemoryProperties(phys, &mem);
    for (uint32_t i = 0; i < mem.memoryTypeCount; ++i) {
        if ((typeBits & (1u << i)) && (mem.memoryTypes[i].propertyFlags & props) == props) {
            return i;
        }
    }
    return 0;
}

bool createBuffer(
    LiveFeedVkSession* s,
    VkDeviceSize size,
    VkBufferUsageFlags usage,
    VkMemoryPropertyFlags memProps,
    VkBuffer& buffer,
    VkDeviceMemory& memory) {
    VkBufferCreateInfo bi{VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};
    bi.size = size;
    bi.usage = usage;
    bi.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    if (vkCreateBuffer(s->device, &bi, nullptr, &buffer) != VK_SUCCESS) return false;
    VkMemoryRequirements req{};
    vkGetBufferMemoryRequirements(s->device, buffer, &req);
    VkMemoryAllocateInfo ai{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
    ai.allocationSize = req.size;
    ai.memoryTypeIndex = findMemoryType(s->physical, req.memoryTypeBits, memProps);
    if (vkAllocateMemory(s->device, &ai, nullptr, &memory) != VK_SUCCESS) return false;
    vkBindBufferMemory(s->device, buffer, memory, 0);
    return true;
}

bool createImage2D(
    LiveFeedVkSession* s,
    uint32_t w,
    uint32_t h,
    VkFormat format,
    VkImageUsageFlags usage,
    VkImage& image,
    VkDeviceMemory& memory) {
    VkImageCreateInfo ii{VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO};
    ii.imageType = VK_IMAGE_TYPE_2D;
    ii.extent = {w, h, 1};
    ii.mipLevels = 1;
    ii.arrayLayers = 1;
    ii.format = format;
    ii.tiling = VK_IMAGE_TILING_OPTIMAL;
    ii.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    ii.usage = usage;
    ii.samples = VK_SAMPLE_COUNT_1_BIT;
    ii.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    if (vkCreateImage(s->device, &ii, nullptr, &image) != VK_SUCCESS) return false;
    VkMemoryRequirements req{};
    vkGetImageMemoryRequirements(s->device, image, &req);
    VkMemoryAllocateInfo ai{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
    ai.allocationSize = req.size;
    ai.memoryTypeIndex =
        findMemoryType(s->physical, req.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    if (vkAllocateMemory(s->device, &ai, nullptr, &memory) != VK_SUCCESS) return false;
    vkBindImageMemory(s->device, image, memory, 0);
    return true;
}

VkImageView createView(LiveFeedVkSession* s, VkImage image, VkFormat format) {
    VkImageViewCreateInfo vi{VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO};
    vi.image = image;
    vi.viewType = VK_IMAGE_VIEW_TYPE_2D;
    vi.format = format;
    vi.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    vi.subresourceRange.levelCount = 1;
    vi.subresourceRange.layerCount = 1;
    VkImageView view = VK_NULL_HANDLE;
    vkCreateImageView(s->device, &vi, nullptr, &view);
    return view;
}

void destroySwapchain(LiveFeedVkSession* s) {
    for (auto fb : s->framebuffers) vkDestroyFramebuffer(s->device, fb, nullptr);
    s->framebuffers.clear();
    for (auto v : s->swapViews) vkDestroyImageView(s->device, v, nullptr);
    s->swapViews.clear();
    s->swapImages.clear();
    if (s->swapchain) {
        vkDestroySwapchainKHR(s->device, s->swapchain, nullptr);
        s->swapchain = VK_NULL_HANDLE;
    }
}

bool createPipeline(LiveFeedVkSession* s);

bool ensureStaging(LiveFeedVkSession* s, VkDeviceSize need) {
    if (s->staging && s->stagingSize >= need) return true;
    if (s->staging) {
        vkDestroyBuffer(s->device, s->staging, nullptr);
        vkFreeMemory(s->device, s->stagingMem, nullptr);
        s->staging = VK_NULL_HANDLE;
        s->stagingMem = VK_NULL_HANDLE;
        s->stagingSize = 0;
    }
    if (!createBuffer(
            s,
            need,
            VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
            VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            s->staging,
            s->stagingMem)) {
        return false;
    }
    s->stagingSize = need;
    return true;
}

bool rebuildSwapchain(LiveFeedVkSession* s) {
    if (!s->device || !s->surface || s->surfaceW <= 0 || s->surfaceH <= 0) return false;
    vkDeviceWaitIdle(s->device);
    destroySwapchain(s);

    VkSurfaceCapabilitiesKHR caps{};
    vkGetPhysicalDeviceSurfaceCapabilitiesKHR(s->physical, s->surface, &caps);
    uint32_t formatCount = 0;
    vkGetPhysicalDeviceSurfaceFormatsKHR(s->physical, s->surface, &formatCount, nullptr);
    std::vector<VkSurfaceFormatKHR> formats(formatCount);
    vkGetPhysicalDeviceSurfaceFormatsKHR(s->physical, s->surface, &formatCount, formats.data());
    VkSurfaceFormatKHR chosen = formats[0];
    for (const auto& f : formats) {
        if (f.format == VK_FORMAT_R8G8B8A8_UNORM || f.format == VK_FORMAT_B8G8R8A8_UNORM) {
            chosen = f;
            break;
        }
    }
    // Keep render-pass attachment format in lockstep with the swapchain.
    if (s->swapFormat != chosen.format || !s->renderPass) {
        if (s->renderPass) {
            vkDestroyRenderPass(s->device, s->renderPass, nullptr);
            s->renderPass = VK_NULL_HANDLE;
        }
        VkAttachmentDescription color{};
        color.format = chosen.format;
        color.samples = VK_SAMPLE_COUNT_1_BIT;
        color.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR;
        color.storeOp = VK_ATTACHMENT_STORE_OP_STORE;
        color.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
        color.finalLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
        VkAttachmentReference colorRef{0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};
        VkSubpassDescription sub{};
        sub.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS;
        sub.colorAttachmentCount = 1;
        sub.pColorAttachments = &colorRef;
        VkRenderPassCreateInfo rpci{VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO};
        rpci.attachmentCount = 1;
        rpci.pAttachments = &color;
        rpci.subpassCount = 1;
        rpci.pSubpasses = &sub;
        if (vkCreateRenderPass(s->device, &rpci, nullptr, &s->renderPass) != VK_SUCCESS) {
            return false;
        }
        // Pipeline is bound to the prior render pass — rebuild it.
        if (s->pipeline) {
            vkDestroyPipeline(s->device, s->pipeline, nullptr);
            s->pipeline = VK_NULL_HANDLE;
        }
        if (!createPipeline(s)) return false;
    }
    s->swapFormat = chosen.format;

    VkExtent2D extent{
        static_cast<uint32_t>(s->surfaceW),
        static_cast<uint32_t>(s->surfaceH),
    };
    if (caps.currentExtent.width != UINT32_MAX) extent = caps.currentExtent;

    uint32_t imageCount = caps.minImageCount + 1;
    if (caps.maxImageCount > 0 && imageCount > caps.maxImageCount) imageCount = caps.maxImageCount;

    VkSwapchainCreateInfoKHR sci{VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR};
    sci.surface = s->surface;
    sci.minImageCount = imageCount;
    sci.imageFormat = chosen.format;
    sci.imageColorSpace = chosen.colorSpace;
    sci.imageExtent = extent;
    sci.imageArrayLayers = 1;
    sci.imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
    sci.imageSharingMode = VK_SHARING_MODE_EXCLUSIVE;
    sci.preTransform = caps.currentTransform;
    sci.compositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
    sci.presentMode = VK_PRESENT_MODE_FIFO_KHR;
    sci.clipped = VK_TRUE;
    if (vkCreateSwapchainKHR(s->device, &sci, nullptr, &s->swapchain) != VK_SUCCESS) return false;

    uint32_t count = 0;
    vkGetSwapchainImagesKHR(s->device, s->swapchain, &count, nullptr);
    s->swapImages.resize(count);
    vkGetSwapchainImagesKHR(s->device, s->swapchain, &count, s->swapImages.data());
    s->swapViews.resize(count);
    s->framebuffers.resize(count);
    for (uint32_t i = 0; i < count; ++i) {
        s->swapViews[i] = createView(s, s->swapImages[i], s->swapFormat);
        VkFramebufferCreateInfo fbi{VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO};
        fbi.renderPass = s->renderPass;
        fbi.attachmentCount = 1;
        fbi.pAttachments = &s->swapViews[i];
        fbi.width = extent.width;
        fbi.height = extent.height;
        fbi.layers = 1;
        vkCreateFramebuffer(s->device, &fbi, nullptr, &s->framebuffers[i]);
    }
    s->surfaceW = static_cast<int>(extent.width);
    s->surfaceH = static_cast<int>(extent.height);
    return true;
}

bool createPipeline(LiveFeedVkSession* s) {
    auto makeModule = [&](const std::vector<uint8_t>& spv) -> VkShaderModule {
        VkShaderModuleCreateInfo ci{VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO};
        ci.codeSize = spv.size();
        ci.pCode = reinterpret_cast<const uint32_t*>(spv.data());
        VkShaderModule mod = VK_NULL_HANDLE;
        vkCreateShaderModule(s->device, &ci, nullptr, &mod);
        return mod;
    };
    VkShaderModule vert = makeModule(s->vertSpv);
    VkShaderModule frag = makeModule(s->fragSpv);
    if (!vert || !frag) return false;

    VkPipelineShaderStageCreateInfo stages[2]{};
    stages[0].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[0].stage = VK_SHADER_STAGE_VERTEX_BIT;
    stages[0].module = vert;
    stages[0].pName = "main";
    stages[1].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[1].stage = VK_SHADER_STAGE_FRAGMENT_BIT;
    stages[1].module = frag;
    stages[1].pName = "main";

    VkPipelineVertexInputStateCreateInfo vi{VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO};
    VkPipelineInputAssemblyStateCreateInfo ia{VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO};
    ia.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
    VkPipelineViewportStateCreateInfo vp{VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO};
    vp.viewportCount = 1;
    vp.scissorCount = 1;
    VkPipelineRasterizationStateCreateInfo rs{VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO};
    rs.polygonMode = VK_POLYGON_MODE_FILL;
    rs.cullMode = VK_CULL_MODE_NONE;
    rs.frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE;
    rs.lineWidth = 1.f;
    VkPipelineMultisampleStateCreateInfo ms{VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO};
    ms.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;
    VkPipelineColorBlendAttachmentState blendAtt{};
    blendAtt.colorWriteMask =
        VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT | VK_COLOR_COMPONENT_B_BIT |
        VK_COLOR_COMPONENT_A_BIT;
    VkPipelineColorBlendStateCreateInfo cb{VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO};
    cb.attachmentCount = 1;
    cb.pAttachments = &blendAtt;
    VkDynamicState dynStates[] = {VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR};
    VkPipelineDynamicStateCreateInfo dyn{VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO};
    dyn.dynamicStateCount = 2;
    dyn.pDynamicStates = dynStates;

    VkGraphicsPipelineCreateInfo pci{VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO};
    pci.stageCount = 2;
    pci.pStages = stages;
    pci.pVertexInputState = &vi;
    pci.pInputAssemblyState = &ia;
    pci.pViewportState = &vp;
    pci.pRasterizationState = &rs;
    pci.pMultisampleState = &ms;
    pci.pColorBlendState = &cb;
    pci.pDynamicState = &dyn;
    pci.layout = s->pipelineLayout;
    pci.renderPass = s->renderPass;
    pci.subpass = 0;
    const bool ok =
        vkCreateGraphicsPipelines(s->device, VK_NULL_HANDLE, 1, &pci, nullptr, &s->pipeline) ==
        VK_SUCCESS;
    vkDestroyShaderModule(s->device, vert, nullptr);
    vkDestroyShaderModule(s->device, frag, nullptr);
    return ok;
}

bool initDevice(LiveFeedVkSession* s) {
    const char* instExt[] = {
        VK_KHR_SURFACE_EXTENSION_NAME,
        VK_KHR_ANDROID_SURFACE_EXTENSION_NAME,
    };
    VkApplicationInfo app{VK_STRUCTURE_TYPE_APPLICATION_INFO};
    app.pApplicationName = "OpenZCine";
    app.apiVersion = VK_API_VERSION_1_1;
    VkInstanceCreateInfo ici{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
    ici.pApplicationInfo = &app;
    ici.enabledExtensionCount = 2;
    ici.ppEnabledExtensionNames = instExt;
    if (vkCreateInstance(&ici, nullptr, &s->instance) != VK_SUCCESS) return false;

    uint32_t devCount = 0;
    vkEnumeratePhysicalDevices(s->instance, &devCount, nullptr);
    if (devCount == 0) return false;
    std::vector<VkPhysicalDevice> devices(devCount);
    vkEnumeratePhysicalDevices(s->instance, &devCount, devices.data());
    s->physical = devices[0];

    uint32_t qCount = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(s->physical, &qCount, nullptr);
    std::vector<VkQueueFamilyProperties> qprops(qCount);
    vkGetPhysicalDeviceQueueFamilyProperties(s->physical, &qCount, qprops.data());
    s->queueFamily = 0;
    for (uint32_t i = 0; i < qCount; ++i) {
        if (qprops[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) {
            s->queueFamily = i;
            break;
        }
    }
    float prio = 1.f;
    VkDeviceQueueCreateInfo qci{VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
    qci.queueFamilyIndex = s->queueFamily;
    qci.queueCount = 1;
    qci.pQueuePriorities = &prio;
    const char* devExt[] = {VK_KHR_SWAPCHAIN_EXTENSION_NAME};
    VkDeviceCreateInfo dci{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};
    dci.queueCreateInfoCount = 1;
    dci.pQueueCreateInfos = &qci;
    dci.enabledExtensionCount = 1;
    dci.ppEnabledExtensionNames = devExt;
    if (vkCreateDevice(s->physical, &dci, nullptr, &s->device) != VK_SUCCESS) return false;
    vkGetDeviceQueue(s->device, s->queueFamily, 0, &s->queue);

    VkCommandPoolCreateInfo cpi{VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};
    cpi.queueFamilyIndex = s->queueFamily;
    cpi.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    vkCreateCommandPool(s->device, &cpi, nullptr, &s->cmdPool);
    VkCommandBufferAllocateInfo cai{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
    cai.commandPool = s->cmdPool;
    cai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    cai.commandBufferCount = 1;
    vkAllocateCommandBuffers(s->device, &cai, &s->cmd);

    VkSemaphoreCreateInfo sci{VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
    vkCreateSemaphore(s->device, &sci, nullptr, &s->imageAvailable);
    vkCreateSemaphore(s->device, &sci, nullptr, &s->renderFinished);
    VkFenceCreateInfo fci{VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
    fci.flags = VK_FENCE_CREATE_SIGNALED_BIT;
    vkCreateFence(s->device, &fci, nullptr, &s->inFlight);

    VkAttachmentDescription color{};
    color.format = VK_FORMAT_R8G8B8A8_UNORM;  // updated after swapchain if needed
    color.samples = VK_SAMPLE_COUNT_1_BIT;
    color.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR;
    color.storeOp = VK_ATTACHMENT_STORE_OP_STORE;
    color.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    color.finalLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
    VkAttachmentReference colorRef{0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};
    VkSubpassDescription sub{};
    sub.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS;
    sub.colorAttachmentCount = 1;
    sub.pColorAttachments = &colorRef;
    VkRenderPassCreateInfo rpci{VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO};
    rpci.attachmentCount = 1;
    rpci.pAttachments = &color;
    rpci.subpassCount = 1;
    rpci.pSubpasses = &sub;
    // Render pass format patched after first swapchain — create placeholder then recreate.
    // For simplicity use B8G8R8A8 which is common on Android.
    color.format = VK_FORMAT_B8G8R8A8_UNORM;
    if (vkCreateRenderPass(s->device, &rpci, nullptr, &s->renderPass) != VK_SUCCESS) return false;

    VkDescriptorSetLayoutBinding binds[3]{};
    binds[0].binding = 0;
    binds[0].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    binds[0].descriptorCount = 1;
    binds[0].stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;
    binds[1].binding = 1;
    binds[1].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    binds[1].descriptorCount = 1;
    binds[1].stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;
    binds[2].binding = 2;
    binds[2].descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
    binds[2].descriptorCount = 1;
    binds[2].stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;
    VkDescriptorSetLayoutCreateInfo dsl{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO};
    dsl.bindingCount = 3;
    dsl.pBindings = binds;
    vkCreateDescriptorSetLayout(s->device, &dsl, nullptr, &s->setLayout);

    VkPipelineLayoutCreateInfo plci{VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};
    plci.setLayoutCount = 1;
    plci.pSetLayouts = &s->setLayout;
    vkCreatePipelineLayout(s->device, &plci, nullptr, &s->pipelineLayout);

    if (!createPipeline(s)) return false;

    VkDescriptorPoolSize sizes[2]{
        {VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 4},
        {VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 2},
    };
    VkDescriptorPoolCreateInfo dpci{VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO};
    dpci.maxSets = 2;
    dpci.poolSizeCount = 2;
    dpci.pPoolSizes = sizes;
    vkCreateDescriptorPool(s->device, &dpci, nullptr, &s->descPool);
    VkDescriptorSetAllocateInfo dsai{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO};
    dsai.descriptorPool = s->descPool;
    dsai.descriptorSetCount = 1;
    dsai.pSetLayouts = &s->setLayout;
    vkAllocateDescriptorSets(s->device, &dsai, &s->descSet);

    VkSamplerCreateInfo sciSamp{VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO};
    sciSamp.magFilter = VK_FILTER_LINEAR;
    sciSamp.minFilter = VK_FILTER_LINEAR;
    sciSamp.addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    sciSamp.addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    sciSamp.addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    vkCreateSampler(s->device, &sciSamp, nullptr, &s->sampler);

    if (!createBuffer(
            s,
            sizeof(GpuParams),
            VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
            VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            s->paramsBuffer,
            s->paramsMem)) {
        return false;
    }
    // 1x1 white feed + identity lut placeholders
    createImage2D(
        s,
        1,
        1,
        VK_FORMAT_R8G8B8A8_UNORM,
        VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT,
        s->feedImage,
        s->feedMem);
    s->feedView = createView(s, s->feedImage, VK_FORMAT_R8G8B8A8_UNORM);
    s->feedW = 1;
    s->feedH = 1;
    createImage2D(
        s,
        1,
        1,
        VK_FORMAT_R8G8B8A8_UNORM,
        VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT,
        s->lutImage,
        s->lutMem);
    s->lutView = createView(s, s->lutImage, VK_FORMAT_R8G8B8A8_UNORM);
    return true;
}

void updateDescriptors(LiveFeedVkSession* s) {
    VkDescriptorImageInfo feedInfo{};
    feedInfo.sampler = s->sampler;
    feedInfo.imageView = s->feedView;
    feedInfo.imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    VkDescriptorImageInfo lutInfo{};
    lutInfo.sampler = s->sampler;
    lutInfo.imageView = s->lutView;
    lutInfo.imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    VkDescriptorBufferInfo bufInfo{};
    bufInfo.buffer = s->paramsBuffer;
    bufInfo.range = sizeof(GpuParams);
    VkWriteDescriptorSet writes[3]{};
    writes[0].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    writes[0].dstSet = s->descSet;
    writes[0].dstBinding = 0;
    writes[0].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    writes[0].descriptorCount = 1;
    writes[0].pImageInfo = &feedInfo;
    writes[1] = writes[0];
    writes[1].dstBinding = 1;
    writes[1].pImageInfo = &lutInfo;
    writes[2].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    writes[2].dstSet = s->descSet;
    writes[2].dstBinding = 2;
    writes[2].descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
    writes[2].descriptorCount = 1;
    writes[2].pBufferInfo = &bufInfo;
    vkUpdateDescriptorSets(s->device, 3, writes, 0, nullptr);
}

void transitionImage(
    VkCommandBuffer cmd,
    VkImage image,
    VkImageLayout oldL,
    VkImageLayout newL,
    VkAccessFlags srcAccess,
    VkAccessFlags dstAccess,
    VkPipelineStageFlags srcStage,
    VkPipelineStageFlags dstStage) {
    VkImageMemoryBarrier b{VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER};
    b.oldLayout = oldL;
    b.newLayout = newL;
    b.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    b.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    b.image = image;
    b.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    b.subresourceRange.levelCount = 1;
    b.subresourceRange.layerCount = 1;
    b.srcAccessMask = srcAccess;
    b.dstAccessMask = dstAccess;
    vkCmdPipelineBarrier(cmd, srcStage, dstStage, 0, 0, nullptr, 0, nullptr, 1, &b);
}

bool uploadRgba(
    LiveFeedVkSession* s,
    VkImage image,
    int w,
    int h,
    const uint8_t* rgba,
    size_t bytes) {
    if (!ensureStaging(s, bytes)) return false;
    void* mapped = nullptr;
    vkMapMemory(s->device, s->stagingMem, 0, bytes, 0, &mapped);
    std::memcpy(mapped, rgba, bytes);
    vkUnmapMemory(s->device, s->stagingMem);

    vkResetCommandBuffer(s->cmd, 0);
    VkCommandBufferBeginInfo bi{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
    bi.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    vkBeginCommandBuffer(s->cmd, &bi);
    transitionImage(
        s->cmd,
        image,
        VK_IMAGE_LAYOUT_UNDEFINED,
        VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        0,
        VK_ACCESS_TRANSFER_WRITE_BIT,
        VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
        VK_PIPELINE_STAGE_TRANSFER_BIT);
    VkBufferImageCopy region{};
    region.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    region.imageSubresource.layerCount = 1;
    region.imageExtent = {static_cast<uint32_t>(w), static_cast<uint32_t>(h), 1};
    vkCmdCopyBufferToImage(
        s->cmd, s->staging, image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);
    transitionImage(
        s->cmd,
        image,
        VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        VK_ACCESS_TRANSFER_WRITE_BIT,
        VK_ACCESS_SHADER_READ_BIT,
        VK_PIPELINE_STAGE_TRANSFER_BIT,
        VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT);
    vkEndCommandBuffer(s->cmd);
    VkSubmitInfo si{VK_STRUCTURE_TYPE_SUBMIT_INFO};
    si.commandBufferCount = 1;
    si.pCommandBuffers = &s->cmd;
    vkQueueSubmit(s->queue, 1, &si, VK_NULL_HANDLE);
    vkQueueWaitIdle(s->queue);
    return true;
}

bool drawFrame(LiveFeedVkSession* s) {
    if (s->paused || !s->swapchain || !s->hasFrame) return true;
    vkWaitForFences(s->device, 1, &s->inFlight, VK_TRUE, UINT64_MAX);
    vkResetFences(s->device, 1, &s->inFlight);
    uint32_t imageIndex = 0;
    VkResult acq =
        vkAcquireNextImageKHR(
            s->device, s->swapchain, UINT64_MAX, s->imageAvailable, VK_NULL_HANDLE, &imageIndex);
    if (acq == VK_ERROR_OUT_OF_DATE_KHR) return rebuildSwapchain(s);
    if (acq != VK_SUCCESS && acq != VK_SUBOPTIMAL_KHR) return false;

    // Push params
    void* mapped = nullptr;
    vkMapMemory(s->device, s->paramsMem, 0, sizeof(GpuParams), 0, &mapped);
    std::memcpy(mapped, &s->params, sizeof(GpuParams));
    vkUnmapMemory(s->device, s->paramsMem);
    updateDescriptors(s);

    vkResetCommandBuffer(s->cmd, 0);
    VkCommandBufferBeginInfo bi{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
    vkBeginCommandBuffer(s->cmd, &bi);
    VkClearValue clear{};
    clear.color = {{0.f, 0.f, 0.f, 1.f}};
    VkRenderPassBeginInfo rp{VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO};
    rp.renderPass = s->renderPass;
    rp.framebuffer = s->framebuffers[imageIndex];
    rp.renderArea.extent = {
        static_cast<uint32_t>(s->surfaceW), static_cast<uint32_t>(s->surfaceH)};
    rp.clearValueCount = 1;
    rp.pClearValues = &clear;
    vkCmdBeginRenderPass(s->cmd, &rp, VK_SUBPASS_CONTENTS_INLINE);
    vkCmdBindPipeline(s->cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, s->pipeline);
    VkViewport viewport{
        0.f, 0.f, static_cast<float>(s->surfaceW), static_cast<float>(s->surfaceH), 0.f, 1.f};
    VkRect2D scissor{{0, 0}, {static_cast<uint32_t>(s->surfaceW), static_cast<uint32_t>(s->surfaceH)}};
    // Letterbox to source aspect when not aspect-fill.
    if (s->params.aspectFill < 0.5f && s->feedW > 0 && s->feedH > 0) {
        const float sw = static_cast<float>(s->surfaceW);
        const float sh = static_cast<float>(s->surfaceH);
        const float src = static_cast<float>(s->feedW) / static_cast<float>(s->feedH);
        const float dst = sw / sh;
        float vw = sw, vh = sh, vx = 0.f, vy = 0.f;
        if (src > dst) {
            vh = sw / src;
            vy = (sh - vh) * 0.5f;
        } else {
            vw = sh * src;
            vx = (sw - vw) * 0.5f;
        }
        viewport = {vx, vy, vw, vh, 0.f, 1.f};
        scissor = {
            {static_cast<int32_t>(vx), static_cast<int32_t>(vy)},
            {static_cast<uint32_t>(vw), static_cast<uint32_t>(vh)}};
    }
    vkCmdSetViewport(s->cmd, 0, 1, &viewport);
    vkCmdSetScissor(s->cmd, 0, 1, &scissor);
    vkCmdBindDescriptorSets(
        s->cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, s->pipelineLayout, 0, 1, &s->descSet, 0, nullptr);
    vkCmdDraw(s->cmd, 3, 1, 0, 0);
    vkCmdEndRenderPass(s->cmd);
    vkEndCommandBuffer(s->cmd);

    VkPipelineStageFlags waitStage = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    VkSubmitInfo si{VK_STRUCTURE_TYPE_SUBMIT_INFO};
    si.waitSemaphoreCount = 1;
    si.pWaitSemaphores = &s->imageAvailable;
    si.pWaitDstStageMask = &waitStage;
    si.commandBufferCount = 1;
    si.pCommandBuffers = &s->cmd;
    si.signalSemaphoreCount = 1;
    si.pSignalSemaphores = &s->renderFinished;
    vkQueueSubmit(s->queue, 1, &si, s->inFlight);

    VkPresentInfoKHR pi{VK_STRUCTURE_TYPE_PRESENT_INFO_KHR};
    pi.waitSemaphoreCount = 1;
    pi.pWaitSemaphores = &s->renderFinished;
    pi.swapchainCount = 1;
    pi.pSwapchains = &s->swapchain;
    pi.pImageIndices = &imageIndex;
    VkResult pr = vkQueuePresentKHR(s->queue, &pi);
    if (pr == VK_ERROR_OUT_OF_DATE_KHR || pr == VK_SUBOPTIMAL_KHR) rebuildSwapchain(s);
    return true;
}

void destroyAll(LiveFeedVkSession* s) {
    if (!s->device) return;
    vkDeviceWaitIdle(s->device);
    destroySwapchain(s);
    if (s->pipeline) vkDestroyPipeline(s->device, s->pipeline, nullptr);
    if (s->pipelineLayout) vkDestroyPipelineLayout(s->device, s->pipelineLayout, nullptr);
    if (s->setLayout) vkDestroyDescriptorSetLayout(s->device, s->setLayout, nullptr);
    if (s->descPool) vkDestroyDescriptorPool(s->device, s->descPool, nullptr);
    if (s->renderPass) vkDestroyRenderPass(s->device, s->renderPass, nullptr);
    if (s->sampler) vkDestroySampler(s->device, s->sampler, nullptr);
    if (s->feedView) vkDestroyImageView(s->device, s->feedView, nullptr);
    if (s->feedImage) vkDestroyImage(s->device, s->feedImage, nullptr);
    if (s->feedMem) vkFreeMemory(s->device, s->feedMem, nullptr);
    if (s->lutView) vkDestroyImageView(s->device, s->lutView, nullptr);
    if (s->lutImage) vkDestroyImage(s->device, s->lutImage, nullptr);
    if (s->lutMem) vkFreeMemory(s->device, s->lutMem, nullptr);
    if (s->paramsBuffer) vkDestroyBuffer(s->device, s->paramsBuffer, nullptr);
    if (s->paramsMem) vkFreeMemory(s->device, s->paramsMem, nullptr);
    if (s->staging) vkDestroyBuffer(s->device, s->staging, nullptr);
    if (s->stagingMem) vkFreeMemory(s->device, s->stagingMem, nullptr);
    if (s->imageAvailable) vkDestroySemaphore(s->device, s->imageAvailable, nullptr);
    if (s->renderFinished) vkDestroySemaphore(s->device, s->renderFinished, nullptr);
    if (s->inFlight) vkDestroyFence(s->device, s->inFlight, nullptr);
    if (s->cmdPool) vkDestroyCommandPool(s->device, s->cmdPool, nullptr);
    if (s->surface) vkDestroySurfaceKHR(s->instance, s->surface, nullptr);
    if (s->device) vkDestroyDevice(s->device, nullptr);
    if (s->instance) vkDestroyInstance(s->instance, nullptr);
}

}  // namespace

extern "C" {

bool LiveFeedVk_IsAvailable() {
    uint32_t count = 0;
    return vkEnumerateInstanceExtensionProperties(nullptr, &count, nullptr) == VK_SUCCESS &&
        count > 0;
}

LiveFeedVkSession* LiveFeedVk_Create(AAssetManager* assets) {
    auto* s = new LiveFeedVkSession();
    s->assets = assets;
    if (!loadAsset(assets, "shaders/vulkan/feed.vert.spv", s->vertSpv) ||
        !loadAsset(assets, "shaders/vulkan/feed.frag.spv", s->fragSpv)) {
        LOGE("failed to load SPIR-V assets");
        delete s;
        return nullptr;
    }
    if (!initDevice(s)) {
        LOGE("Vulkan device init failed");
        destroyAll(s);
        delete s;
        return nullptr;
    }
    LOGI("Vulkan live feed session ready");
    return s;
}

void LiveFeedVk_Destroy(LiveFeedVkSession* session) {
    if (!session) return;
    std::lock_guard<std::mutex> guard(session->lock);
    destroyAll(session);
    delete session;
}

bool LiveFeedVk_AttachSurface(LiveFeedVkSession* session, ANativeWindow* window) {
    if (!session || !window) return false;
    std::lock_guard<std::mutex> guard(session->lock);
    if (session->window) {
        ANativeWindow_release(session->window);
        session->window = nullptr;
    }
    if (session->surface) {
        vkDestroySurfaceKHR(session->instance, session->surface, nullptr);
        session->surface = VK_NULL_HANDLE;
    }
    session->window = window;
    ANativeWindow_acquire(window);
    VkAndroidSurfaceCreateInfoKHR sci{VK_STRUCTURE_TYPE_ANDROID_SURFACE_CREATE_INFO_KHR};
    sci.window = window;
    if (vkCreateAndroidSurfaceKHR(session->instance, &sci, nullptr, &session->surface) !=
        VK_SUCCESS) {
        return false;
    }
    session->surfaceW = ANativeWindow_getWidth(window);
    session->surfaceH = ANativeWindow_getHeight(window);
    // Recreate render pass if swap format differs — rebuildSwapchain uses B8G8R8A8 commonly.
    return rebuildSwapchain(session);
}

void LiveFeedVk_DetachSurface(LiveFeedVkSession* session) {
    if (!session) return;
    std::lock_guard<std::mutex> guard(session->lock);
    if (session->device) vkDeviceWaitIdle(session->device);
    destroySwapchain(session);
    if (session->surface) {
        vkDestroySurfaceKHR(session->instance, session->surface, nullptr);
        session->surface = VK_NULL_HANDLE;
    }
    if (session->window) {
        ANativeWindow_release(session->window);
        session->window = nullptr;
    }
}

void LiveFeedVk_Resize(LiveFeedVkSession* session, int width, int height) {
    if (!session) return;
    std::lock_guard<std::mutex> guard(session->lock);
    session->surfaceW = width;
    session->surfaceH = height;
    if (session->surface) rebuildSwapchain(session);
}

void LiveFeedVk_Resume(LiveFeedVkSession* session) {
    if (!session) return;
    std::lock_guard<std::mutex> guard(session->lock);
    session->paused = false;
}

void LiveFeedVk_Pause(LiveFeedVkSession* session) {
    if (!session) return;
    std::lock_guard<std::mutex> guard(session->lock);
    session->paused = true;
}

void LiveFeedVk_ClearFrame(LiveFeedVkSession* session) {
    if (!session) return;
    std::lock_guard<std::mutex> guard(session->lock);
    session->hasFrame = false;
}

void LiveFeedVk_ClearPlan(LiveFeedVkSession* session) {
    if (!session) return;
    std::lock_guard<std::mutex> guard(session->lock);
    session->hasPlan = false;
    session->params.lutSize = 0.f;
}

bool LiveFeedVk_SubmitBitmap(LiveFeedVkSession* session, JNIEnv* env, jobject bitmap) {
    if (!session || !bitmap) return false;
    std::lock_guard<std::mutex> guard(session->lock);
    AndroidBitmapInfo info{};
    if (AndroidBitmap_getInfo(env, bitmap, &info) != ANDROID_BITMAP_RESULT_SUCCESS) return false;
    if (info.format != ANDROID_BITMAP_FORMAT_RGBA_8888) return false;
    void* pixels = nullptr;
    if (AndroidBitmap_lockPixels(env, bitmap, &pixels) != ANDROID_BITMAP_RESULT_SUCCESS) {
        return false;
    }
    const int w = static_cast<int>(info.width);
    const int h = static_cast<int>(info.height);
    const size_t bytes = static_cast<size_t>(w) * static_cast<size_t>(h) * 4u;
    if (w != session->feedW || h != session->feedH) {
        if (session->feedView) vkDestroyImageView(session->device, session->feedView, nullptr);
        if (session->feedImage) vkDestroyImage(session->device, session->feedImage, nullptr);
        if (session->feedMem) vkFreeMemory(session->device, session->feedMem, nullptr);
        createImage2D(
            session,
            w,
            h,
            VK_FORMAT_R8G8B8A8_UNORM,
            VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT,
            session->feedImage,
            session->feedMem);
        session->feedView = createView(session, session->feedImage, VK_FORMAT_R8G8B8A8_UNORM);
        session->feedW = w;
        session->feedH = h;
    }
    const bool ok =
        uploadRgba(session, session->feedImage, w, h, static_cast<const uint8_t*>(pixels), bytes);
    AndroidBitmap_unlockPixels(env, bitmap);
    if (!ok) return false;
    session->params.sourceSize[0] = static_cast<float>(w);
    session->params.sourceSize[1] = static_cast<float>(h);
    session->hasFrame = true;
    return drawFrame(session);
}

bool LiveFeedVk_SetPlan(
    LiveFeedVkSession* session,
    int lutSize,
    const uint8_t* lutRgba,
    int lutBytes,
    int /*limitsPaintSize*/,
    const uint8_t* /*limitsPaintRgba*/,
    int /*limitsPaintBytes*/,
    int /*limitsWeightSize*/,
    const uint8_t* /*limitsWeightRgba*/,
    int /*limitsWeightBytes*/,
    bool /*limitsOn*/,
    bool peakingOn,
    const float* peakingColor3,
    const float* deLogCurve5,
    float peakingThreshold,
    float peakingRamp,
    bool zebraHighlightOn,
    float zebraHighlight,
    const float* zebraHighlightColor3,
    bool zebraMidtoneOn,
    float zebraMidtone,
    const float* zebraMidtoneColor3,
    bool aspectFill) {
    if (!session) return false;
    std::lock_guard<std::mutex> guard(session->lock);
    session->params = {};
    session->params.lutSize = static_cast<float>(lutSize);
    session->params.peakingOn = peakingOn ? 1.f : 0.f;
    session->params.zebraHighlightOn = zebraHighlightOn ? 1.f : 0.f;
    session->params.zebraMidtoneOn = zebraMidtoneOn ? 1.f : 0.f;
    session->params.peakingThreshold = peakingThreshold;
    session->params.peakingRamp = peakingRamp;
    session->params.zebraHighlight = zebraHighlight;
    session->params.zebraMidtone = zebraMidtone;
    session->params.aspectFill = aspectFill ? 1.f : 0.f;
    // Preserve sourceSize across plan updates (set when frames upload).
    session->params.sourceSize[0] = static_cast<float>(session->feedW);
    session->params.sourceSize[1] = static_cast<float>(session->feedH);
    if (deLogCurve5) {
        session->params.deLogCurve0to3[0] = deLogCurve5[0];
        session->params.deLogCurve0to3[1] = deLogCurve5[1];
        session->params.deLogCurve0to3[2] = deLogCurve5[2];
        session->params.deLogCurve0to3[3] = deLogCurve5[3];
        session->params.deLogCurve4 = deLogCurve5[4];
    } else {
        // Identity quarter-axis fallback (linear).
        session->params.deLogCurve0to3[0] = 0.f;
        session->params.deLogCurve0to3[1] = 0.25f;
        session->params.deLogCurve0to3[2] = 0.5f;
        session->params.deLogCurve0to3[3] = 0.75f;
        session->params.deLogCurve4 = 1.f;
    }
    if (peakingColor3) {
        session->params.peakingColor[0] = peakingColor3[0];
        session->params.peakingColor[1] = peakingColor3[1];
        session->params.peakingColor[2] = peakingColor3[2];
        session->params.peakingColor[3] = 1.f;
    }
    if (zebraHighlightColor3) {
        session->params.zebraHighlightColor[0] = zebraHighlightColor3[0];
        session->params.zebraHighlightColor[1] = zebraHighlightColor3[1];
        session->params.zebraHighlightColor[2] = zebraHighlightColor3[2];
        session->params.zebraHighlightColor[3] = 1.f;
    }
    if (zebraMidtoneColor3) {
        session->params.zebraMidtoneColor[0] = zebraMidtoneColor3[0];
        session->params.zebraMidtoneColor[1] = zebraMidtoneColor3[1];
        session->params.zebraMidtoneColor[2] = zebraMidtoneColor3[2];
        session->params.zebraMidtoneColor[3] = 1.f;
    }
    if (lutSize >= 2 && lutRgba && lutBytes == lutSize * lutSize * lutSize * 4) {
        // AGSL packing: width = n*n, height = n
        const int tw = lutSize * lutSize;
        const int th = lutSize;
        if (session->lutView) vkDestroyImageView(session->device, session->lutView, nullptr);
        if (session->lutImage) vkDestroyImage(session->device, session->lutImage, nullptr);
        if (session->lutMem) vkFreeMemory(session->device, session->lutMem, nullptr);
        createImage2D(
            session,
            tw,
            th,
            VK_FORMAT_R8G8B8A8_UNORM,
            VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT,
            session->lutImage,
            session->lutMem);
        session->lutView = createView(session, session->lutImage, VK_FORMAT_R8G8B8A8_UNORM);
        session->lutSize = lutSize;
        if (!uploadRgba(session, session->lutImage, tw, th, lutRgba, static_cast<size_t>(lutBytes))) {
            return false;
        }
    }
    session->hasPlan = true;
    return true;
}

}  // extern "C"
