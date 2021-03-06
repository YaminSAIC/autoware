// ------------------------------------------------------------------
// Copyright (c) 2015 Microsoft
// Licensed under The MIT License
// Modified from MATLAB Faster R-CNN (https://github.com/shaoqingren/faster_rcnn)
// ------------------------------------------------------------------


//headers in local files
#include "lidar_point_pillars/nms_cuda.h"

/*
the paralled steps:
1. copy memory
2. calculate the iou
3. mask out for each refence boxes

key points:
1. the iou is calculated as same as tensorflow object detection: scores for every 2 boxes.
2. the mask is represented by bits so that the results can be used directly by |
3. all the masks are calculated in cpu, because you need to remove in one oder.
4. preprocessing: sort by sore, is done in cpu.
*/



// single box iou
__device__ inline float devIoU(float const *const a, float const *const b)
{
  float left = max(a[0], b[0]), right = min(a[2], b[2]);
  float top = max(a[1], b[1]), bottom = min(a[3], b[3]);
  float width = max(right - left + 1, 0.f), height = max(bottom - top + 1, 0.f);
  float interS = width * height;
  float Sa = (a[2] - a[0] + 1) * (a[3] - a[1] + 1);
  float Sb = (b[2] - b[0] + 1) * (b[3] - b[1] + 1);
  return interS / (Sa + Sb - interS);
}


// dev_boxes are sorted for nms beforehand

__global__ void nms_kernel(const int n_boxes, const float nms_overlap_thresh,
                           const float *dev_boxes, unsigned long long *dev_mask,
                           const int NUM_BOX_CORNERS)
{
  const int row_start = blockIdx.y;
  const int col_start = blockIdx.x;
  
  // blockDim is nothing to do with blockIdx
  // it is the threads
  const int block_threads = blockDim.x;
  
  // when enough boxes, row_size and col_size both are block_threads
  // row_size and col_size are for one block
  const int row_size =
      min(n_boxes - row_start * block_threads, block_threads);
  const int col_size =
      min(n_boxes - col_start * block_threads, block_threads);
  
  // copy memory from global to shared memory!!
  // every thread in a block is for a 2d box's corners
  // from now you need to pay attention to the reflection of block to the real pos
  // and only think in one block
  __shared__ float block_boxes[NUM_THREADS_MACRO * NUM_2D_BOX_CORNERS_MACRO];
  if (threadIdx.x < col_size)
  {
    // 0 1 2 3 4 is the corners of the box, so the box is a 4 corner-box
    // block boxes is shared memory for a block. shared memory is shared by block
    // Each thread is for copying one box 
    // left: thread position in a block                           right: global position of the thread
    block_boxes[threadIdx.x * NUM_BOX_CORNERS + 0] = dev_boxes[(block_threads * col_start + threadIdx.x) * NUM_BOX_CORNERS + 0];
    block_boxes[threadIdx.x * NUM_BOX_CORNERS + 1] = dev_boxes[(block_threads * col_start + threadIdx.x) * NUM_BOX_CORNERS + 1];
    block_boxes[threadIdx.x * NUM_BOX_CORNERS + 2] = dev_boxes[(block_threads * col_start + threadIdx.x) * NUM_BOX_CORNERS + 2];
    block_boxes[threadIdx.x * NUM_BOX_CORNERS + 3] = dev_boxes[(block_threads * col_start + threadIdx.x) * NUM_BOX_CORNERS + 3];
  }
  __syncthreads();
  
  // this if is for last block which has more threads than the boxes.
  if (threadIdx.x < row_size)
  {
    // row is for sorted dev box index, so no need to consider col
    const int cur_box_idx = block_threads * row_start + threadIdx.x;
    const float cur_box[NUM_2D_BOX_CORNERS_MACRO] = {dev_boxes[cur_box_idx*NUM_BOX_CORNERS + 0],
                                                     dev_boxes[cur_box_idx*NUM_BOX_CORNERS + 1],
                                                     dev_boxes[cur_box_idx*NUM_BOX_CORNERS + 2],
                                                     dev_boxes[cur_box_idx*NUM_BOX_CORNERS + 3]};
    unsigned long long t = 0;
    int start = 0;
    if (row_start == col_start)
    {
      start = threadIdx.x + 1;
    }
    
    // col_size=blockdim=thread_num_in_one_block
    // why block-wise not thread-wise here?
    // because now it is mapping to row, col should be reduced!!!!!!!!!!!!!!
    for (int i = start; i < col_size; i++)
    { 
      // iou for nms.. 
      //         current    threadbox in blockboxes
      // cur_box is the sorted box by confidence
      if (devIoU(cur_box, block_boxes + i * NUM_BOX_CORNERS) > nms_overlap_thresh)
      {
        //  00000000100000000  1 is for the boxes overlaps too much
        t |= 1ULL << i;
      }
    }
    
    // from here we know col_blocks have every boxes
    const int col_blocks = DIVUP(n_boxes, block_threads);
    // col is for all the compared boxes, why no thread??
    dev_mask[cur_box_idx * col_blocks + col_start] = t;
  }
}

NMSCuda::NMSCuda(const int NUM_THREADS, const int NUM_BOX_CORNERS ,const float nms_overlap_threshold):
NUM_THREADS_(NUM_THREADS),
NUM_BOX_CORNERS_(NUM_BOX_CORNERS),
nms_overlap_threshold_(nms_overlap_threshold)
{
}

void NMSCuda::doNMSCuda(const int host_filter_count, float* dev_sorted_box_for_nms, int* out_keep_inds, int& out_num_to_keep)
{
  const int col_blocks = DIVUP(host_filter_count, NUM_THREADS_);
  dim3 blocks(DIVUP(host_filter_count, NUM_THREADS_),DIVUP(host_filter_count, NUM_THREADS_));
  dim3 threads(NUM_THREADS_);

  unsigned long long *dev_mask = NULL;
  
  // why here dev_mask is for block not for thread?
  // host_filter's result if represented with blocks of boxes instead of single boxes
  GPU_CHECK(cudaMalloc(&dev_mask, host_filter_count * col_blocks * sizeof(unsigned long long)));

  nms_kernel<<<blocks, threads>>>(host_filter_count, nms_overlap_threshold_, dev_sorted_box_for_nms, dev_mask, NUM_BOX_CORNERS_);

  // postprocess for nms output
  std::vector<unsigned long long> host_mask(host_filter_count * col_blocks);
  GPU_CHECK(cudaMemcpy(&host_mask[0],dev_mask, sizeof(unsigned long long) * host_filter_count * col_blocks,cudaMemcpyDeviceToHost));
  std::vector<unsigned long long> remv(col_blocks);
  // initialize with 0
  // final remv is recorded with blocks too.
  memset(&remv[0], 0, sizeof(unsigned long long) * col_blocks);
  
  // for each filter, or we say reference box
  for (int i = 0; i < host_filter_count; i++)
  {
    
    int nblock = i /  NUM_THREADS_;
    int inblock = i % NUM_THREADS_;

    if (!(remv[nblock] & (1ULL << inblock)))
    {
      out_keep_inds[out_num_to_keep++] = i;
      // for one filter bit add masks for every blocks
      unsigned long long *p = &host_mask[0] + i * col_blocks;
      for (int j = nblock; j < col_blocks; j++)
      {
        remv[j] |= p[j];
      }
    }
  }
  GPU_CHECK(cudaFree(dev_mask));
}
