#include <vector>

#include "caffe/filler.hpp"
#include "caffe/layer.hpp"
#include "caffe/util/region_im2col.hpp"
#include "caffe/util/math_functions.hpp"
#include "caffe/vision_layers.hpp"

namespace caffe {

template <typename Dtype>
__global__ void move_back_kernel(const int n, const Dtype* data_im, const Dtype* data_mask, const Dtype* top_buffer,
    const int height, const int width, const int mask_cnt, Dtype* data) {
  CUDA_KERNEL_LOOP(index, n) {
    const int w = index % width;
    const int h = (index / width) % height;
    const int temp = static_cast<int>(data_mask[h * width + w]);
    if (temp == -1)
      data[index] = data_im[index];
    else
    {
      const int c = (index / width) / height;
      data[index] = top_buffer[c * mask_cnt + temp];
    }
  }
}

template <typename Dtype>
void RegionConvolutionLayer<Dtype>::Forward_gpu(const vector<Blob<Dtype>*>& bottom,
      const vector<Blob<Dtype>*>& top) {
  
  const Dtype* weights = this->blobs_[0]->gpu_data();
  const Dtype* bottom_data = bottom[0]->gpu_data();
  Dtype* top_data = top[0]->mutable_gpu_data();
  Dtype* top_buffer = top_buffer_.mutable_gpu_data();
  const Dtype* mask_data = bottom[1]->gpu_data();
  const Dtype* index_1 = bottom[2]->gpu_data()+bottom[2]->offset(0, 0, 0, 1);
  const Dtype* index_2 = bottom[2]->gpu_data()+bottom[2]->offset(0, 0, 1, 1);
  const int count = top[0]->count();
  mask_cnt_ = bottom[2]->cpu_data()[0];


  //region im2col
  region_im2col_gpu(bottom_data, index_1, index_2, mask_cnt_, conv_in_channels_, conv_in_height_, conv_in_width_,
        kernel_h_, kernel_w_, pad_h_, pad_w_, dilation_h_, dilation_w_, col_buffer_.mutable_gpu_data());

  //gemmm
  caffe_gpu_gemm<Dtype>(CblasNoTrans, CblasNoTrans, conv_out_channels_, mask_cnt_, kernel_dim_,
      (Dtype)1., weights, col_buffer_.gpu_data(),
      (Dtype)0., top_buffer);

  //bias
  if (this->bias_term_) {
    caffe_gpu_gemm<Dtype>(CblasNoTrans, CblasNoTrans, num_output_,
    mask_cnt_, 1, (Dtype)1., this->blobs_[1]->gpu_data(), bias_multiplier_.gpu_data(),
    (Dtype)1., top_buffer);
  }

  //move back
  move_back_kernel<Dtype><<<CAFFE_GET_BLOCKS(count), CAFFE_CUDA_NUM_THREADS>>>(
        count, bottom_data, mask_data, top_buffer_.gpu_data(), conv_in_height_, conv_in_width_, mask_cnt_,
        top_data);

  CUDA_POST_KERNEL_CHECK;
}



template <typename Dtype>
__global__ void pick_out_kernel(const int n, const Dtype* data_diff,
    const int height, const int width,
    const Dtype* index_1, const Dtype* index_2,
    const int mask_cnt, Dtype* diff_buffer) {
  CUDA_KERNEL_LOOP(index, n) {
    const int m_index = index % mask_cnt;
    const int c = index / mask_cnt;
    const int h = index_1[m_index];
    const int w = index_2[m_index];
    diff_buffer[index] = data_diff[(c * height + h) * width + w];
  }
}



template <typename Dtype>
void RegionConvolutionLayer<Dtype>::Backward_gpu(const vector<Blob<Dtype>*>& top,
      const vector<bool>& propagate_down, const vector<Blob<Dtype>*>& bottom) {

  const Dtype* weights = this->blobs_[0]->gpu_data();
  Dtype* weight_diff = this->blobs_[0]->mutable_gpu_diff();

  const Dtype* top_diff = top[0]->gpu_diff();

  const Dtype* bottom_data = bottom[0]->gpu_data();
  Dtype* bottom_diff = bottom[0]->mutable_gpu_diff();

  const Dtype* mask_data = bottom[1]->gpu_data();
  const Dtype* index_1 = bottom[2]->gpu_data()+bottom[2]->offset(0, 0, 0, 1);
  const Dtype* index_2 = bottom[2]->gpu_data()+bottom[2]->offset(0, 0, 1, 1);
  const int count = top[0]->count();
  mask_cnt_ = bottom[2]->cpu_data()[0];

  //pick_out_kernel
  int num_kernels = conv_out_channels_ * mask_cnt_;
  pick_out_kernel<Dtype><<<CAFFE_GET_BLOCKS(num_kernels), CAFFE_CUDA_NUM_THREADS>>>(
        num_kernels, top_diff, height_out_, width_out_, index_1, index_2, mask_cnt_, top_buffer_.mutable_gpu_diff());



  // Bias gradient, if necessary.
  if (this->bias_term_ && this->param_propagate_down_[1]) {
    caffe_gpu_gemv<Dtype>(CblasNoTrans, num_output_, mask_cnt_, 1.,
        top_buffer_.gpu_diff(), bias_multiplier_.gpu_data(), 1., this->blobs_[1]->mutable_gpu_diff());
  }

  // weight gradient
  if (this->param_propagate_down_[0]) {

    region_im2col_gpu(bottom_data, index_1, index_2, mask_cnt_, conv_in_channels_, conv_in_height_, conv_in_width_,
            kernel_h_, kernel_w_, pad_h_, pad_w_, dilation_h_, dilation_w_, col_buffer_.mutable_gpu_data());

    caffe_gpu_gemm<Dtype>(CblasNoTrans, CblasTrans, conv_out_channels_,
        kernel_dim_, mask_cnt_,
        (Dtype)1., top_buffer_.gpu_diff() , col_buffer_.gpu_data(),
        (Dtype)1., this->blobs_[0]->mutable_gpu_data());
  }

  //data gradient
  if (propagate_down[0]) {
    caffe_gpu_gemm<Dtype>(CblasTrans, CblasNoTrans, kernel_dim_,
        mask_cnt_, conv_out_channels_,
        (Dtype)1., weights , top_buffer_.gpu_diff(),
        (Dtype)0., col_buffer_.mutable_gpu_data());

    region_col2im_gpu(col_buffer_.gpu_data(), 
        index_1, index_2, mask_data,
        mask_cnt_, conv_in_channels_,
        conv_in_height_, conv_in_width_, kernel_h_, kernel_w_,
        pad_h_, pad_w_, dilation_h_, dilation_w_,
        bottom_diff);
  }
}

INSTANTIATE_LAYER_GPU_FUNCS(RegionConvolutionLayer);

}  // namespace caffe
