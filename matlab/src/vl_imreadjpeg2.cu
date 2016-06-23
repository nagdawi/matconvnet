/** @file vl_imreadjpeg2.cu
 ** @brief Load images asynchronously
 ** @author Andrea Vedaldi
 **/

/*
Copyright (C) 2014-16 Andrea Vedaldi.
All rights reserved.

This file is part of the VLFeat library and is made available under
the terms of the BSD license (see the COPYING file).
*/

#include "bits/impl/tinythread.h"
#include "bits/imread.hpp"
#include "bits/impl/imread_helpers.hpp"

#include <assert.h>
#include <vector>
#include <string>
#include <algorithm>
#include <iostream>
#include <sstream>
#include <cstdlib>

#include "bits/datamex.hpp"
#include "bits/mexutils.h"

static int verbosity = 0 ;

/* option codes */
enum {
  opt_num_threads = 0,
  opt_prefetch,
  opt_resize,
  opt_pack,
  opt_gpu,
  opt_verbose,
  opt_subtract_average,
  opt_crop_size,
  opt_crop_location,
  opt_crop_anisotropy,
  opt_flip,
  opt_contrast,
  opt_saturation,
  opt_brightness
} ;

/* options */
VLMXOption  options [] = {
  {"NumThreads",       1,   opt_num_threads        },
  {"Prefetch",         0,   opt_prefetch           },
  {"Verbose",          0,   opt_verbose            },
  {"Resize",           1,   opt_resize             },
  {"Pack",             0,   opt_pack               },
  {"GPU",              0,   opt_gpu                },
  {"SubtractAverage",  1,   opt_subtract_average   },
  {"CropAnisotropy",   1,   opt_crop_anisotropy    },
  {"CropSize",         1,   opt_crop_size          },
  {"CropLocation",     1,   opt_crop_location      },
  {"Flip",             0,   opt_flip               },
  {"Brightness",       1,   opt_brightness         },
  {"Contrast",         1,   opt_contrast           },
  {"Saturation",       1,   opt_saturation         },
  {0,                  0,   0                      }
} ;

enum {
  IN_FILENAMES = 0, IN_END
} ;

enum {
  OUT_IMAGES = 0, OUT_END
} ;

/* ---------------------------------------------------------------- */
/*                                                           Logger */
/* ---------------------------------------------------------------- */

namespace vl {
  class Logger
  {
  public:
    Logger() ;
    ~Logger() ;
    std::ostringstream & getStream() ;
  protected:
    std::ostringstream stringStream ;
  private:
    // Disable
    Logger(const Logger&) ;
    Logger& operator= (const Logger&) ;
  } ;
}

vl::Logger::Logger()
{ }

vl::Logger::~Logger()
{
  printf("%s\n", stringStream.str().c_str()) ;
  //fflush(stdout) ;
}

std::ostringstream &
vl::Logger::getStream()
{
  return stringStream ;
}

#define LOGERROR \
vl::Logger().getStream() \
<<"[info] "<<__func__<<"::"

#define LOG(level) \
if (verbosity < level) { } \
else vl::Logger().getStream() \
<<"[info] "<<__func__<<"::"

/* ---------------------------------------------------------------- */
/*                                                            Batch */
/* ---------------------------------------------------------------- */

class Batch
{
public:
  struct Item
  {
    enum State {
      prefetch,
      fetch,
      ready
    } state ;

    Batch const & batch ;
    std::string name ;
    vl::ImageShape shape ;
    mxArray * array ;
    vl::ErrorCode error ;
    char errorMessage [512] ;
    bool borrowed ;
    vl::MexTensor cpuArray ;
    vl::MexTensor gpuArray ;
    int index ;

    size_t outputWidth ;
    size_t outputHeight ;
    size_t outputNumChannels ;
    size_t cropWidth ;
    size_t cropHeight ;
    size_t cropOffsetX ;
    size_t cropOffsetY ;
    bool flip ;

    float brightnessShift [3] ;
    float contrastShift ;
    float saturationShift ;

    Item(Batch const & batch) ;
    mxArray * relinquishArray() ;
  } ;

  enum ResizeMethod {
    noResize,
    resizeShortestSide,
    fixedSize
  } ;

  enum PackingMethod {
    individualArrays,
    singleArray
  };

  enum CropLocation {
    cropCenter,
    cropRandom
  } ;

  Batch(vl::MexContext & context) ;
  ~Batch() ;
  vl::ErrorCode init() ;
  void finalize() ;
  vl::ErrorCode registerItem(std::string const & name) ;

  size_t getNumberOfItems() const ;
  Item * getItem(int index) ;
  void clear() ;
  void sync() const ;
  vl::ErrorCode prefetch() ;
  mxArray * relinquishArray() ;

  void setGpuMode(bool gpu) ;
  void setPackingMethod(PackingMethod method) ;
  void setResizeMethod(ResizeMethod method, int height, int width) ;

  void setAverage(double average []) ;
  void setColorDeviation(double brightness [], double contrast, double saturation) ;
  void setFlipMode(bool x) ;
  void setCropAnisotropy(double minAnisotropy, double maxAnisotropy) ;
  void setCropSize(double minSize, double maxSize) ;
  void setCropLocation(CropLocation location) ;
  PackingMethod getPackingMethod() const  ;

  Item * borrowNextItem() ;
  void returnItem(Item * item) ;

private:
  vl::MexContext & context ;

  tthread::mutex mutable mutex ;
  tthread::condition_variable mutable waitNextItemToBorrow ;
  tthread::condition_variable mutable waitCompletion ;
  bool quit ;
  typedef std::vector<Item*> items_t ;
  items_t items ;
  int nextItem ;
  int numReturnedItems ;

  enum PackingMethod packingMethod ;
  enum ResizeMethod resizeMethod ;
  int resizeHeight ;
  int resizeWidth ;
  bool gpuMode ;

  double average [3] ;
  double contrastDeviation ;
  double saturationDeviation ;
  double brightnessDeviation [9] ;
  double minCropAnisotropy ;
  double maxCropAnisotropy ;
  double minCropSize ;
  double maxCropSize ;
  CropLocation cropLocation ;
  bool flipMode ;

  vl::MexTensor cpuPack ;
  vl::MexTensor gpuPack ;
  friend class ReaderTask ;
  int gpuDevice ;
#if ENABLE_GPU
  bool cudaStreamInitialized ;
  cudaStream_t cudaStream ;
#endif
} ;

Batch::Item::Item(Batch const & batch)
: batch(batch),
  cpuArray(batch.context),
  gpuArray(batch.context),
  borrowed(false),
  error(vl::VLE_Success),
  state(ready),
  flip(false)
{
  memset(errorMessage,sizeof(errorMessage),0) ;
}

mxArray * Batch::Item::relinquishArray()
{
  if (batch.gpuMode) {
    return gpuArray.relinquish() ;
  } else {
    return cpuArray.relinquish() ;
  }
}

mxArray * Batch::relinquishArray()
{
  if (gpuMode) {
    return gpuPack.relinquish() ;
  } else {
    return cpuPack.relinquish() ;
  }
}

Batch::Batch(vl::MexContext & context)
: context(context),
  cpuPack(context),
  gpuPack(context),
  quit(true),
  resizeMethod(noResize),
  packingMethod(individualArrays),
  gpuMode(false),
  numReturnedItems(0)
{ }

Batch::~Batch()
{
  finalize() ;
}

size_t Batch::getNumberOfItems() const
{
  return items.size() ;
}

Batch::Item * Batch::getItem(int index)
{
  return items[index] ;
}

vl::ErrorCode Batch::init()
{
  finalize() ;
  LOG(2)<<"beginning batch" ;
  quit = false ;
  nextItem = 0 ;
  numReturnedItems = 0 ;

  // Restore defaults
  memset(brightnessDeviation, 0, sizeof(brightnessDeviation)) ;
  contrastDeviation = 0. ;
  saturationDeviation = 0. ;
  memset(average, 0, sizeof(average)) ;

  cropLocation = cropCenter ;
  minCropSize = 1. ;
  maxCropSize = 1. ;
  minCropAnisotropy = 1. ;
  maxCropAnisotropy = 1. ;
  flipMode = false ;

  packingMethod = individualArrays ;
  resizeMethod = noResize ;
  gpuMode = false ;
  gpuDevice = -1 ;
#if ENABLE_GPU
  if (cudaStreamInitialized) {
    cudaStreamDestroy(cudaStream) ;
    cudaStreamInitialized = false ;
  }
#endif
  return vl::VLE_Success ;
}

void Batch::finalize()
{
  LOG(2)<<"finalizing batch" ;
  
  // Clear current batch
  clear() ;

  // Signal waiting threads that we will stop
  {
    tthread::lock_guard<tthread::mutex> lock(mutex) ;
    quit = true ;
    waitNextItemToBorrow.notify_all() ;
  }
}

Batch::Item * Batch::borrowNextItem()
{
  tthread::lock_guard<tthread::mutex> lock(mutex) ;
  while (true) {
    if (quit) { return NULL ; }
    if (nextItem < items.size()) {
      Item * item = items[nextItem++] ;
      item->borrowed = true ;
      return item ;
    }
    waitNextItemToBorrow.wait(mutex) ;
  }
}

void Batch::returnItem(Batch::Item * item)
{
  tthread::lock_guard<tthread::mutex> lock(mutex) ;
  numReturnedItems ++ ;
  if (item->state == Item::fetch &&
      numReturnedItems == items.size() &&
      packingMethod == singleArray &&
      gpuMode) {
#if ENABLE_GPU
    LOG(2) << "push to GPU the pack" ;
    cudaError_t cerror ;
    cerror = cudaMemcpyAsync (gpuPack.getMemory(),
                              cpuPack.getMemory(),
                              gpuPack.getNumElements() * sizeof(float),
                              cudaMemcpyHostToDevice,
                              cudaStream) ;
    if (cerror != cudaSuccess) {
      item->error = vl::VLE_Cuda ;
      snprintf(item->errorMessage, sizeof(item->errorMessage),
              "cudaMemcpyAsnyc : '%s'", cudaGetErrorString(cerror)) ;
    }
#endif
  }
  item->borrowed = false ;
  item->state = Batch::Item::ready ;
  waitCompletion.notify_all() ;
}

void Batch::clear()
{
  tthread::lock_guard<tthread::mutex> lock(mutex) ;

  // Stop threads from getting more tasks
  nextItem = items.size() ;

  // Wait for all thread to return their items
  for (int i = 0 ; i < items.size() ; ++i) {
    while (items[i]->borrowed) {
      waitCompletion.wait(mutex) ;
    }
    delete items[i] ;
  }
  items.clear() ;

  // At the end of the current (empty) list
  nextItem = 0 ;
  numReturnedItems = 0 ;
}

void Batch::sync() const
{
  tthread::lock_guard<tthread::mutex> lock(mutex) ;

  // Wait for threads to complete work for all items
  for (int i = 0 ; i < items.size() ; ++i) {
    while (items[i]->state != Item::ready) {
      waitCompletion.wait(mutex) ;
    }
  }

  if (gpuMode) {
#if ENABLE_GPU
    cudaError_t cerror ;
    cerror = cudaStreamSynchronize(cudaStream) ;
    if (cerror != cudaSuccess) {
      LOGERROR << "CUDA error while synchronizing a stream: '" << cudaGetErrorString(cerror) << '\'' ;
    }
#endif
  }
}

vl::ErrorCode Batch::registerItem(std::string const & name)
{
  tthread::lock_guard<tthread::mutex> lock(mutex) ;
  Item * item = new Item(*this) ;
  item->index = items.size() ;
  item->name = name ;
  item->state = Item::prefetch ;
  items.push_back(item) ;
  waitNextItemToBorrow.notify_one() ;
  return vl::VLE_Success ;
}

void Batch::setGpuMode(bool gpu)
{
  tthread::lock_guard<tthread::mutex> lock(mutex) ;
#if ENABLE_GPU
  if (gpu) {
    cudaGetDevice(&gpuDevice) ;
    if (!cudaStreamInitialized) {
      cudaError_t cerror ;
      cerror = cudaStreamCreateWithFlags(&cudaStream, cudaStreamNonBlocking) ;
      if (cerror != cudaSuccess) {
        LOGERROR
        << "CUDA error while creating a stream '"
        << cudaGetErrorString(cerror) << '\"' ;
      } else {
        cudaStreamInitialized = true ;
      }
    }
  }
#endif
  gpuMode = gpu ;
}

void Batch::setResizeMethod(Batch::ResizeMethod method, int height, int width)
{
  resizeMethod = method ;
  resizeHeight = height ;
  resizeWidth = width ;
}

void Batch::setPackingMethod(Batch::PackingMethod method)
{
  assert(method == individualArrays || method == singleArray) ;
  packingMethod = method ;
}

Batch::PackingMethod Batch::getPackingMethod() const
{
  return packingMethod ;
}

void Batch::setAverage(double average [])
{
  ::memcpy(this->average, average, sizeof(this->average)) ;
}

void Batch::setColorDeviation(double brightness [], double contrast, double saturation)
{
  ::memcpy(brightnessDeviation, brightness, sizeof(brightnessDeviation)) ;
  contrastDeviation = contrast ;
  saturationDeviation = saturation ;
}

void Batch::setFlipMode(bool x)
{
  flipMode = x ;
}

void Batch::setCropAnisotropy(double minAnisotropy, double maxAnisotropy)
{
  assert(minAnisotropy <= maxAnisotropy) ;
  assert(0.0 <= minAnisotropy && minAnisotropy <= 1.0) ;
  minCropAnisotropy = minAnisotropy ;
  maxCropAnisotropy = maxAnisotropy ;
}

void Batch::setCropSize(double minSize, double maxSize)
{
  assert(minSize <= maxSize) ;
  assert(0.0 <= minSize && minSize <= 1.0) ;
  assert(0.0 <= maxSize && maxSize <= 1.0) ;
  minCropSize = minSize ;
  maxCropSize = maxSize ;
}

void Batch::setCropLocation(CropLocation location)
{
  assert(location == cropCenter || location == cropRandom) ;
  cropLocation = location ;
}

//void Batch::getItemTransformation(Item * item)
//{
//
//}

vl::ErrorCode Batch::prefetch()
{
  // Wait for reader threads to initialize the shape of the images
  // and then perform the requried allocations.
  sync() ;

  // In packing mode, preallocate all memory here.
  if (packingMethod == singleArray) {
    assert(resizeMethod == fixedSize) ;
    vl::TensorShape shape(resizeHeight, resizeWidth, 3, getNumberOfItems()) ;
    cpuPack.init(vl::VLDT_CPU, vl::VLDT_Float, shape) ;
    cpuPack.makePersistent() ;
    if (gpuMode) {
      gpuPack.init(vl::VLDT_GPU, vl::VLDT_Float, shape) ;
      gpuPack.makePersistent() ;
    }
  }

  // Get ready to reprocess all items.
  nextItem = 0 ;
  numReturnedItems = 0 ;

  for (int i = 0 ; i < getNumberOfItems() ; ++ i) {
    Batch::Item * item = getItem(i) ;
    if (item->error == vl::VLE_Success) {
      if (verbosity >= 2) {
        mexPrintf("%20s: %d x %d x %d\n", item->name.c_str(), item->shape.width, item->shape.height, item->shape.depth) ;
      }
    } else {
      mexPrintf("%20s: error '%s'\n", item->name.c_str(), item->errorMessage) ;
    }

    // Determine the shape of (height and width) of the output image. This is either
    // the same as the input image, or with a fixed size for the shortest side,
    // or a fixed size for both sides.

    int outputHeight ;
    int outputWidth ;
    double cropHeight ;
    double cropWidth ;
    int dx ;
    int dy ;

    switch (resizeMethod) {
      case noResize:
        outputHeight = item->shape.height ;
        outputWidth = item->shape.width ;
        break ;

      case resizeShortestSide: {
        double scale1 = (double)resizeHeight / item->shape.width ;
        double scale2 = (double)resizeHeight / item->shape.height ;
        double scale = std::max(scale1, scale2) ;
        outputHeight = std::max(1.0, round(scale * item->shape.height)) ;
        outputWidth = std::max(1.0, round(scale * item->shape.width)) ;
        break ;
      }

      case fixedSize:
        outputHeight = resizeHeight ;
        outputWidth = resizeWidth ;
        break ;
    }

    // Determine the aspect ratio of the crop in the input image.
    {
      double anisotropyRatio = 1.0 ;
      if (minCropAnisotropy == 0 && maxCropAnisotropy == 0) {
        // Stretch crop to have the same shape as the input.
        double inputAspect = (double)item->shape.width / item->shape.height ;
        double outputAspect = (double)outputWidth / outputHeight ;
        anisotropyRatio = outputAspect / inputAspect ;
      } else {
        double z = (double)rand() / RAND_MAX ;
        anisotropyRatio = z * (maxCropAnisotropy - minCropAnisotropy) + minCropAnisotropy ;
      }
      cropWidth = outputWidth * anisotropyRatio ;
      cropHeight = outputHeight / anisotropyRatio ;
    }

    // Determine the crop size.
    {
      double scale = std::min(item->shape.width / cropWidth,
                              item->shape.height / cropHeight) ;
      double z = (double)rand() / RAND_MAX ;
      double size = z * (maxCropSize - minCropSize) + minCropSize ;
      cropWidth *= scale * size ;
      cropHeight *= scale * size ;
    }

    cropWidth = std::min(round(cropWidth), (double)item->shape.width) ;
    cropHeight = std::min(round(cropHeight), (double)item->shape.height) ;

    // Determine the crop location.
    {
      dx = item->shape.width - cropWidth ;
      dy = item->shape.height - cropHeight ;
      switch (cropLocation) {
        case cropCenter:
          dx = (dx+1)/2 ;
          dy = (dy+1)/2 ;
          break ;
        case cropRandom:
          dx = rand() % (dx + 1) ;
          dy = rand() % (dy + 1) ;
          break ;
        default:
          LOGERROR << "cropLocation not set" ;
      }
    }

    // Save.
    item->outputWidth = outputWidth ;
    item->outputHeight = outputHeight ;
    item->outputNumChannels = (packingMethod == individualArrays) ? item->shape.depth : 3 ;
 ;
    item->cropWidth = cropWidth ;
    item->cropHeight = cropHeight ;
    item->cropOffsetX = dx ;
    item->cropOffsetY = dy ;
    item->flip = flipMode && (rand() > RAND_MAX/2) ;

    // Color processing.
    item->saturationShift = 1. + saturationDeviation * (2.*(double)rand()/RAND_MAX - 1) ;
    item->contrastShift = 1. + contrastDeviation * (2.*(double)rand()/RAND_MAX - 1.) ;
    {
      int numChannels = item->outputNumChannels ;
      double w [3] ;
      for (int i = 0 ; i < numChannels ; ++i) { w[i] = vl::randn() ; }
      for (int i = 0 ; i < numChannels ; ++i) {
        item->brightnessShift[i] = 0. ;
        for (int j = 0 ; j < numChannels ; ++j) {
          item->brightnessShift[i] += brightnessDeviation[i + 3*j] * w[i] ;
        }
      }
    }

    LOG(2)
    << "input ("  << item->shape.width << " x " << item->shape.height << " x " << item->shape.depth << ") "
    << "output (" << item->outputWidth << " x " << item->outputHeight << " x " << item->outputNumChannels << ") "
    << "crop ("   << item->cropWidth   << " x " << item->cropHeight   << ") "
    << "offset (" << item->cropOffsetX << ", "  << item->cropOffsetY  << ")" ;

    if (packingMethod == individualArrays) {
      vl::TensorShape shape(outputHeight, outputWidth, item->outputNumChannels, 1) ;
      item->cpuArray.init(vl::VLDT_CPU, vl::VLDT_Float, shape) ;
      item->cpuArray.makePersistent() ;
      if (gpuMode) {
        item->gpuArray.init(vl::VLDT_GPU, vl::VLDT_Float, shape) ;
        item->gpuArray.makePersistent() ;
      }
    }

    // Ready to fetch
    item->state = Item::fetch ;
    waitNextItemToBorrow.notify_one() ;
  }

  return vl::VLE_Success ;
}


/* ---------------------------------------------------------------- */
/*                                                       ReaderTask */
/* ---------------------------------------------------------------- */

class ReaderTask
{
public:
  ReaderTask() ;
  ~ReaderTask() { finalize() ; }
  vl::ErrorCode init(Batch * batch, int index) ;
  void finalize() ;

private:
  int index ;
  Batch * batch ;
  tthread::thread * thread ;
  vl::ImageReader * reader ;
  static void threadEntryPoint(void * thing) ;
  void entryPoint() ;
  void * getBuffer(int index, size_t size) ;
  int gpuDevice ;

private:
  ReaderTask(ReaderTask const &) ;
  ReaderTask & operator= (ReaderTask const &) ;

  struct Buffer {
    void * memory ;
    size_t size ;
  } buffers [2] ;
} ;

void ReaderTask::threadEntryPoint(void * thing)
{
  ((ReaderTask*)thing)->entryPoint() ;
}

ReaderTask::ReaderTask()
: batch(NULL), thread(NULL), reader(NULL)
{
  memset(buffers, 0, sizeof(buffers)) ;
}

void * ReaderTask::getBuffer(int index, size_t size)
{
  if (buffers[index].size < size) {
    if (buffers[index].memory) {
      free(buffers[index].memory) ;
    }
    buffers[index].memory = malloc(size) ;
    buffers[index].size = size ;
  }
  return buffers[index].memory ;
}

void ReaderTask::entryPoint()
{
  LOG(2) << "reader " << index << " task staring" ;

  while (true) {
#if ENABLE_GPU
    if (batch->gpuMode && batch->gpuDevice != gpuDevice) {
      LOG(2) << "reader " << index << " setting GPU device" ;
      cudaSetDevice(batch->gpuDevice) ;
      cudaGetDevice(&gpuDevice) ;
    }
#endif

    Batch::Item * item = batch->borrowNextItem() ;
    LOG(3) << "borrowed " << item ;
    if (item == NULL) { break ; }
    if (item->error != vl::VLE_Success) {
      batch->returnItem(item) ;
      continue ;
    }

    switch (item->state) {
      case Batch::Item::prefetch: {
        item->error = reader->readShape(item->shape, item->name.c_str()) ;
        if (item->error != vl::VLE_Success) {
          snprintf(item->errorMessage, sizeof(item->errorMessage), "%s", reader->getLastErrorMessage()) ;
        }
        break ;
      }

      case Batch::Item::fetch: {
        // Get the CPU buffer that will hold the pixels.
        float * outputPixels;
        if (batch->getPackingMethod() == Batch::individualArrays) {
          outputPixels = (float*)item->cpuArray.getMemory() ;
        } else {
          outputPixels = (float*)batch->cpuPack.getMemory() + item->outputHeight*item->outputWidth*3*item->index ;
        }

        // Read full image.
        float * inputPixels = (float*)getBuffer(0,
                                                item->shape.height *
                                                item->shape.width *
                                                item->shape.depth * sizeof(float)) ;
        item->error = reader->readPixels(inputPixels, item->name.c_str()) ;
        if (item->error != vl::VLE_Success) {
          snprintf(item->errorMessage, sizeof(item->errorMessage), "%s", reader->getLastErrorMessage()) ;
          break ;
        }

        // Crop.
        float * temp = (float*)getBuffer(1,
                                         item->outputHeight *
                                         item->shape.width *
                                         item->shape.depth * sizeof(float)) ;

        vl::impl::imageResizeVertical(temp, inputPixels,
                                      item->outputHeight,
                                      item->shape.height,
                                      item->shape.width,
                                      item->shape.depth,
                                      item->cropHeight,
                                      item->cropOffsetY) ;

        vl::impl::imageResizeVertical(outputPixels, temp,
                                      item->outputWidth,
                                      item->shape.width,
                                      item->outputHeight,
                                      item->shape.depth,
                                      item->cropWidth,
                                      item->cropOffsetX,
                                      item->flip) ;

        // Postprocess colors.
        {
          float dv [3] ;
          float * channels [3] ;
          size_t K = item->outputNumChannels ;
          size_t n = item->outputHeight*item->outputWidth ;
          for (int k = 0 ; k < K ; ++k) {
            channels[k] = outputPixels + n * k ;
          }
          for (int k = 0 ; k < item->shape.depth ; ++k) {
            dv[k] = (1. - 2. * item->contrastShift) *
            (batch->average[k] + item->brightnessShift[k]);
            if (item->contrastShift != 1.) {
              float mu = 0.f ;
              float const * pixel = channels[k] ;
              float const * end = channels[k] + n ;
              while (pixel != end) { mu += *pixel++ ; }
              mu /= n ;
              dv[k] -= (1.0 - item->contrastShift) * mu ;
            }
          }
          {
            float const * end = channels[0] + n ;
            float v [3] ;
            if (K == 3 && item->shape.depth == 3) {
              float const a = item->contrastShift * item->saturationShift ;
              float const b = item->contrastShift * (1. - item->saturationShift) / K ;
              while (channels[0] != end) {
                float mu = 0.f ;
                v[0] = *channels[0] + dv[0] ; mu += v[0] ;
                v[1] = *channels[1] + dv[1] ; mu += v[1] ;
                v[2] = *channels[2] + dv[2] ; mu += v[2] ;
                *channels[0]++ = a * v[0] + b * mu ;
                *channels[1]++ = a * v[1] + b * mu ;
                *channels[2]++ = a * v[2] + b * mu ;
              }
            } else if (K == 3 && item->shape.depth == 1) {
              float const a = item->contrastShift * item->saturationShift ;
              float const b = item->contrastShift * (1. - item->saturationShift) / K ;
              while (channels[0] != end) {
                float mu = 0.f ;
                v[0] = *channels[0] + dv[0] ; mu += v[0] ;
                v[1] = *channels[0] + dv[1] ; mu += v[1] ;
                v[2] = *channels[0] + dv[2] ; mu += v[2] ;
                *channels[0]++ = a * v[0] + b * mu ;
                *channels[1]++ = a * v[1] + b * mu ;
                *channels[2]++ = a * v[2] + b * mu ;
              }
            } else {
              float const a = item->contrastShift ;
              while (channels[0] != end) {
                *channels[0]++ = a * (*channels[0] + dv[0]) ;
              }
            }
          }
        }

        // Copy to GPU.
        if (batch->getPackingMethod() == Batch::individualArrays && batch->gpuMode) {
          cudaError_t cerror ;
          cerror = cudaMemcpyAsync (item->gpuArray.getMemory(),
                                    outputPixels,
                                    item->gpuArray.getNumElements() * sizeof(float),
                                    cudaMemcpyHostToDevice,
                                    batch->cudaStream) ;
          if (cerror != cudaSuccess) {
            item->error = vl::VLE_Cuda ;
            snprintf(item->errorMessage, sizeof(item->errorMessage),
                     "CUDA error while copying memory from host to device: '%s'", cudaGetErrorString(cerror)) ;
            break ;
          }
        }
        break ;
      }

      case Batch::Item::ready:
        break ;
    }
    batch->returnItem(item) ;
  }
  LOG(2) << "reader " << index << " task quitting" ;
}

void ReaderTask::finalize()
{
  LOG(2)<<"finalizing reader " << index ;
  for (int i = 0 ; i < sizeof(buffers)/sizeof(Buffer) ; ++i) {
    if (buffers[i].memory) {
      free(buffers[i].memory) ;
      buffers[i].memory = NULL ;
      buffers[i].size = 0 ;
    }
  }

  if (reader) {
    delete reader ;
    reader = NULL ;
  }
  if (thread) {
    if (thread->joinable()) {
      thread->join() ;
    }
    delete thread ;
    thread = NULL ;
  }
  index = -1 ;
  batch = NULL ;
}

vl::ErrorCode ReaderTask::init(Batch * batch, int index)
{
  finalize() ;
  this->batch = batch ;
  this->index = index ;
  thread = new tthread::thread(threadEntryPoint, this) ;
  reader = new vl::ImageReader() ;
  return vl::VLE_Success ;
}

/* ---------------------------------------------------------------- */
/*                                                            Cache */
/* ---------------------------------------------------------------- */

vl::MexContext context ;
Batch batch(context) ;
bool batchIsInitialized = false ;
typedef std::vector<ReaderTask*> readers_t ;
readers_t readers ;

void atExit()
{
  if (batchIsInitialized) {
    batch.finalize() ;
    batchIsInitialized = false ;
  }
  for (int r = 0 ; r < readers.size() ; ++r) {
    readers[r]->finalize() ;
    delete readers[r] ;
  }
  readers.clear() ;
}

/* ---------------------------------------------------------------- */
/*                                                            Cache */
/* ---------------------------------------------------------------- */

void mexFunction(int nout, mxArray *out[],
                 int nin, mxArray const *in[])
{
  bool prefetch = false ;
  bool gpuMode = false ;
  int requestedNumThreads = readers.size() ;
  int opt ;
  int next = IN_END ;
  mxArray const *optarg ;

  Batch::PackingMethod packingMethod = Batch::individualArrays ;
  Batch::ResizeMethod resizeMethod = Batch::noResize ;
  int resizeWidth = -1 ;
  int resizeHeight = -1 ;
  vl::ErrorCode error ;

  double average [3] = {0.} ;
  double brightnessDeviation [9] = {0.} ;
  double saturationDeviation = 0. ;
  double contrastDeviation = 0. ;
  bool flipMode = false ;
  Batch::CropLocation cropLocation = Batch::cropCenter ;
  double minCropSize = 1.0, maxCropSize = 1.0 ;
  double minCropAnisotropy = 1.0, maxCropAnisotropy = 1.0 ;

  verbosity = 0 ;

  /* -------------------------------------------------------------- */
  /*                                            Check the arguments */
  /* -------------------------------------------------------------- */

  mexAtExit(atExit) ;

  if (nin < 1) {
    vlmxError(VLMXE_IllegalArgument, "There is less than one argument.") ;
  }

  while ((opt = vlmxNextOption (in, nin, options, &next, &optarg)) >= 0) {
    switch (opt) {
      case opt_verbose :
        ++ verbosity ;
        break ;

      case opt_prefetch :
        prefetch = true ;
        break ;

      case opt_pack :
        packingMethod = Batch::singleArray ;
        break ;

      case opt_gpu :
        gpuMode = true ;
        break ;

      case opt_num_threads :
        requestedNumThreads = (int)mxGetScalar(optarg) ;
        break ;

      case opt_resize :
        if (!vlmxIsPlainVector(optarg, -1)) {
          vlmxError(VLMXE_IllegalArgument, "RESIZE is not a plain vector.") ;
        }
        switch (mxGetNumberOfElements(optarg)) {
          case 1 :
            resizeMethod = Batch::resizeShortestSide ;
            resizeHeight = (int)mxGetPr(optarg)[0] ;
            resizeWidth = (int)mxGetPr(optarg)[0] ;
            break ;
          case 2 :
            resizeMethod = Batch::fixedSize ;
            resizeHeight = (int)mxGetPr(optarg)[0] ;
            resizeWidth = (int)mxGetPr(optarg)[1] ;
            break;
          default:
            vlmxError(VLMXE_IllegalArgument, "RESIZE does not have one or two dimensions.") ;
            break ;
        }
        if (resizeHeight < 1 || resizeWidth < 1) {
          vlmxError(VLMXE_IllegalArgument, "An element of RESIZE is smaller than one.") ;
        }
        break ;

      case opt_brightness: {
        if (!vlmxIsPlainMatrix(optarg, -1, -1)) {
          vlmxError(VLMXE_IllegalArgument, "BRIGHTNESS is not a plain matrix.") ;
        }
        size_t n = mxGetNumberOfElements(optarg) ;
        memset(brightnessDeviation, 0, sizeof(brightnessDeviation)) ;
        if (n == 1) {
          double x = mxGetPr(optarg)[0] ;
          brightnessDeviation[0] = x;
          brightnessDeviation[3] = x;
          brightnessDeviation[8] = x;
        } else if (n == 3) {
          double const* x = mxGetPr(optarg) ;
          brightnessDeviation[0] = x[0];
          brightnessDeviation[3] = x[1];
          brightnessDeviation[8] = x[2];
        } else if (n == 9) {
          memcpy(brightnessDeviation, mxGetPr(optarg), sizeof(brightnessDeviation)) ;
        } else {
          vlmxError(VLMXE_IllegalArgument, "BRIGHTNESS does not have 1, 3, or 9 elements.") ;
        }
        break ;
      }

      case opt_saturation: {
        if (!vlmxIsPlainScalar(optarg)) {
          vlmxError(VLMXE_IllegalArgument, "SATURATION is not a plain scalar.") ;
        }
        double x = mxGetPr(optarg)[0] ;
        if (x < 0 || x > 1.0) {
          vlmxError(VLMXE_IllegalArgument, "SATURATION is not in the [0,1] range..") ;
        }
        saturationDeviation = x ;
        break ;
      }

      case opt_contrast: {
        if (!vlmxIsPlainScalar(optarg)) {
          vlmxError(VLMXE_IllegalArgument, "CONTRAST is not a plain scalar.") ;
        }
        double x = mxGetPr(optarg)[0] ;
        if (x < 0 || x > 1.0) {
          vlmxError(VLMXE_IllegalArgument, "CONTRAST is not in the [0,1] range..") ;
        }
        contrastDeviation = x ;
        break ;
      }

      case opt_crop_anisotropy: {
        if (!vlmxIsPlainVector(optarg, 2)) {
          vlmxError(VLMXE_IllegalArgument, "CROPANISOTROPY is not a plain vector with two components.") ;
        }
        minCropAnisotropy = mxGetPr(optarg)[0] ;
        maxCropAnisotropy = mxGetPr(optarg)[1] ;
        if (minCropAnisotropy < 0.0 || minCropAnisotropy > maxCropAnisotropy) {
          vlmxError(VLMXE_IllegalArgument, "CROPANISOTROPY values are not in the legal range.") ;
        }
        break ;
      }

      case opt_crop_size: {
        if (!vlmxIsPlainVector(optarg, 2)) {
          vlmxError(VLMXE_IllegalArgument, "CROPSIZE is not a plain vector with two components.") ;
        }
        minCropSize = mxGetPr(optarg)[0] ;
        maxCropSize = mxGetPr(optarg)[1] ;
        if (minCropSize < 0.0 || minCropSize > maxCropSize || maxCropSize > 1.0) {
          vlmxError(VLMXE_IllegalArgument, "CROPSIZE values are not in the legal range.") ;

        }
        break ;
      }

      case opt_crop_location: {
        if (!vlmxIsString(optarg, -1)) {
          vlmxError(VLMXE_IllegalArgument, "CROPLOCATION is not a string") ;
        }
        if (vlmxCompareToStringI(optarg, "random") == 0) {
          cropLocation = Batch::cropRandom ;
        } else if (vlmxCompareToStringI(optarg, "center") == 0) {
          cropLocation = Batch::cropCenter ;
        } else {
          vlmxError(VLMXE_IllegalArgument, "CROPLOCATION value unknown.") ;
        }
        break ;
      }

      case opt_subtract_average: {
        if (!vlmxIsPlainVector(optarg, 3)) {
          vlmxError(VLMXE_IllegalArgument, "SUBTRACTAVERAGE is not a plain vector with three elements.") ;
        }
        double * x = mxGetPr(optarg) ;
        average[0] = (float)x[0] ;
        average[1] = (float)x[1] ;
        average[2] = (float)x[2] ;
        break ;
      }

      case opt_flip: {
        flipMode = true ;
        break ;
      }
    }
  }

  /* -------------------------------------------------------------- */
  /*                                                    Do the work */
  /* -------------------------------------------------------------- */

  if (!mxIsCell(in[IN_FILENAMES])) {
    vlmxError(VLMXE_IllegalArgument, "FILENAMES is not a cell array of strings.") ;
  }

  // Prepare batch.
  if (!batchIsInitialized) {
    error = batch.init() ;
    if (error != vl::VLE_Success) {
      vlmxError(VLMXE_Execution, "Could not initialize a batch structure") ;
    }
    batchIsInitialized = true ;
  }

  // Prepare reader tasks.
  requestedNumThreads = std::max(requestedNumThreads, 1) ;
  if (readers.size() != requestedNumThreads) {
    batch.clear() ; // make sure no reader still pending on current batch
    for (int r = 0 ; r < requestedNumThreads ; ++r) {
      readers.push_back(new ReaderTask()) ;
      vl::ErrorCode error = readers[r]->init(&batch, r) ;
      if (error != vl::VLE_Success) {
        vlmxError(VLMXE_Execution, "Could not create the requested number of threads") ;
      }
    }
  }

  // Extract filenames as strings.
  bool sameAsPrefeteched = true ;
  std::vector<std::string> filenames ;
  for (int i = 0 ; i < (int)mxGetNumberOfElements(in[IN_FILENAMES]) ; ++i) {
    mxArray* filenameArray = mxGetCell(in[IN_FILENAMES], i) ;
    if (!vlmxIsString(filenameArray,-1)) {
      vlmxError(VLMXE_IllegalArgument, "FILENAMES contains an entry that is not a string.") ;
    }
    char filename [512] ;
    mxGetString (filenameArray, filename, sizeof(filename)/sizeof(char)) ;
    filenames.push_back(std::string(filename)) ;
    sameAsPrefeteched &= (i < batch.getNumberOfItems() && batch.getItem(i)->name == filenames[i]) ;
  }

  // If the list of names is not the same as the prefetched ones,
  // start a new cycle.
  if (!sameAsPrefeteched) {
    batch.clear() ;

    // Check compatibility of options
    if (packingMethod == Batch::singleArray && resizeMethod != Batch::fixedSize) {
      vlmxError(VLMXE_IllegalArgument, "PACK must be used in combination with resizing to a fixed size.") ;
    }

    if (verbosity >= 2) {
      mexPrintf("vl_imreadjpeg: gpu mode: %s\n", gpuMode?"yes":"no") ;
      mexPrintf("vl_imreadjpeg: crop anisotropy: [%.1g, %.1g]\n",
                minCropAnisotropy, maxCropAnisotropy) ;
      mexPrintf("vl_imreadjpeg: crop size: [%.1g, %.1g]\n",
                minCropSize, maxCropSize) ;
    }


    batch.setGpuMode(gpuMode) ;
    batch.setFlipMode(flipMode) ;
    batch.setCropLocation(cropLocation) ;
    batch.setCropAnisotropy(minCropAnisotropy, maxCropAnisotropy) ;
    batch.setCropSize(minCropSize, maxCropSize) ;
    batch.setPackingMethod(packingMethod) ;
    batch.setResizeMethod(resizeMethod, resizeHeight, resizeWidth) ;
    batch.setAverage(average) ;
    batch.setColorDeviation(brightnessDeviation,
                            contrastDeviation,
                            saturationDeviation) ;
    for (int i = 0 ; i < filenames.size() ; ++ i) {
      batch.registerItem(filenames[i]) ;
    }

    batch.prefetch() ;
  }

  // Done if prefetching only.
  if (prefetch) { return ; }

  // Return result.
  batch.sync() ;

  switch (batch.getPackingMethod()) {
    case Batch::singleArray: {
      mwSize dims [] = {1,1} ;
      out[OUT_IMAGES] = mxCreateCellArray(2, dims) ;
      mxSetCell(out[OUT_IMAGES], 0, batch.relinquishArray()) ;
      break ;
    }

    case Batch::individualArrays:
      out[OUT_IMAGES] = mxCreateCellArray(mxGetNumberOfDimensions(in[IN_FILENAMES]),
                                          mxGetDimensions(in[IN_FILENAMES])) ;
      for (int i = 0 ; i < batch.getNumberOfItems() ; ++i) {
        Batch::Item * item = batch.getItem(i) ;
        if (item->error != vl::VLE_Success) {
          vlmxWarning(VLMXE_Execution, "could not read image '%s' because '%s'",
                      item->name.c_str(),
                      item->errorMessage) ;
        } else {
          mxSetCell(out[OUT_IMAGES], i, item->relinquishArray()) ;
        }
      }
      break ;
  }

  // Finalize.
  batch.clear() ;
}
