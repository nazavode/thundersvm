//
// Created by jiashuai on 17-9-21.
//

#include <thundersvm/kernel/smo_kernel.h>
#include <thrust/sort.h>
#include <thrust/system/cuda/detail/par.h>
#include <thundersvm/model/svmmodel.h>
#include <thundersvm/kernel/kernelmatrix_kernel.h>

SvmModel::SvmModel(DataSet &dataSet, const SvmParam &svmParam) :
        dataSet(dataSet), svmParam(svmParam), n_instances(dataSet.total_count()) {}

int SvmModel::max2power(int n) const {
    return int(pow(2, floor(log2f(float(n)))));
}

void
SvmModel::smo_solver(const KernelMatrix &k_mat, const SyncData<int> &y, SyncData<real> &alpha, real &rho,
                     SyncData<real> &f_val, real eps, real C, int ws_size) const {
    uint n_instances = k_mat.n_instances();
    uint q = ws_size / 2;

    SyncData<int> working_set(ws_size);
    SyncData<int> working_set_first_half(q);
    SyncData<int> working_set_last_half(q);
    working_set_first_half.set_device_data(working_set.device_data());
    working_set_last_half.set_device_data(&working_set.device_data()[q]);
    working_set_first_half.set_host_data(working_set.host_data());
    working_set_last_half.set_host_data(&working_set.host_data()[q]);

    SyncData<int> f_idx(n_instances);
    SyncData<int> f_idx2sort(n_instances);
    SyncData<real> f_val2sort(n_instances);
    SyncData<real> alpha_diff(ws_size);
    SyncData<real> diff_and_bias(2);

    SyncData<real> k_mat_rows(ws_size * k_mat.n_instances());
    SyncData<real> k_mat_rows_first_half(q * k_mat.n_instances());
    SyncData<real> k_mat_rows_last_half(q * k_mat.n_instances());
    k_mat_rows_first_half.set_device_data(k_mat_rows.device_data());
    k_mat_rows_last_half.set_device_data(&k_mat_rows.device_data()[q * k_mat.n_instances()]);
    for (int i = 0; i < n_instances; ++i) {
        f_idx[i] = i;
    }
    LOG(INFO) << "training start";
    for (int iter = 1;; ++iter) {
        //select working set
        f_idx2sort.copy_from(f_idx);
        f_val2sort.copy_from(f_val);
        thrust::sort_by_key(thrust::cuda::par, f_val2sort.device_data(), f_val2sort.device_data() + n_instances,
                            f_idx2sort.device_data(), thrust::less<real>());
        vector<int> ws_indicator(n_instances, 0);
        if (1 == iter) {
            select_working_set(ws_indicator, f_idx2sort, y, alpha, C, working_set);
            k_mat.get_rows(working_set, k_mat_rows);
        } else {
            working_set_first_half.copy_from(working_set_last_half);
            for (int i = 0; i < q; ++i) {
                ws_indicator[working_set[i]] = 1;
            }
            select_working_set(ws_indicator, f_idx2sort, y, alpha, C, working_set_last_half);
            k_mat_rows_first_half.copy_from(k_mat_rows_last_half);
            k_mat.get_rows(working_set_last_half, k_mat_rows_last_half);
        }

        //local smo
        size_t smem_size = ws_size * sizeof(real) * 3 + 2 * sizeof(float);
        local_smo << < 1, ws_size, smem_size >> >
                                   (y.device_data(), f_val.device_data(), alpha.device_data(), alpha_diff.device_data(),
                                          working_set.device_data(), ws_size, C, k_mat_rows.device_data(), n_instances,
                                          eps, diff_and_bias.device_data());
        LOG_EVERY_N(10, INFO) << "diff=" << diff_and_bias[0];
        if (diff_and_bias[0] < eps) {
            rho = diff_and_bias[1];
            break;
        }

        //update f
        SAFE_KERNEL_LAUNCH(update_f, f_val.device_data(), ws_size, alpha_diff.device_data(), k_mat_rows.device_data(),
                           n_instances);
    }
}

void
SvmModel::select_working_set(vector<int> &ws_indicator, const SyncData<int> &f_idx2sort, const SyncData<int> &y,
                             const SyncData<real> &alpha, real C, SyncData<int> &working_set) const {
    int n_instances = ws_indicator.size();
    int p_left = 0;
    int p_right = n_instances - 1;
    int n_selected = 0;
    const int *index = f_idx2sort.host_data();
    while (n_selected < working_set.count()) {
        int i;
        if (p_left < n_instances) {
            i = index[p_left];
            while (ws_indicator[i] == 1 || !((y[i] > 0 && alpha[i] < C) || (y[i] < 0 && alpha[i] > 0))) {
            	//construct working set of I_up
                p_left++;
                if (p_left == n_instances) break;
                i = index[p_left];
            }
            if (p_left < n_instances) {
                working_set[n_selected++] = i;
                ws_indicator[i] = 1;
            }
        }
        if (p_right >= 0) {
            i = index[p_right];
            while ((ws_indicator[i] == 1 || !((y[i] > 0 && alpha[i] > 0) || (y[i] < 0 && alpha[i] < C)))) {
            	//construct working set of I_low
                p_right--;
                if (p_right == -1) break;
                i = index[p_right];
            }
            if (p_right >= 0) {
                working_set[n_selected++] = i;
                ws_indicator[i] = 1;
            }
        }

    }
}

vector<real> SvmModel::predict(const DataSet::node2d &instances, int batch_size) {
    //TODO use thrust
    //prepare device data
    int n_sv = coef.size();
    SyncData<real> coef(n_sv);
    SyncData<int> sv_index(n_sv);
    SyncData<int> sv_start(1);
    SyncData<int> sv_count(1);
    SyncData<real> rho(1);

    sv_start[0] = 0;
    sv_count[0] = n_sv;
    rho[0] = this->rho;
    coef.copy_from(this->coef.data(), n_sv);
    sv_index.copy_from(this->sv_index.data(), n_sv);

    //compute kernel values
    KernelMatrix k_mat(sv, dataSet.n_features(), svmParam.gamma);

    auto batch_start = instances.begin();
    auto batch_end = batch_start;
    vector<real> predict_y;
    while (batch_end != instances.end()) {
        while (batch_end != instances.end() && batch_end - batch_start < batch_size) batch_end++;
        DataSet::node2d batch_ins(batch_start, batch_end);
        SyncData<real> kernel_values(batch_ins.size() * sv.size());
        k_mat.get_rows(batch_ins, kernel_values);
        SyncData<real> dec_values(batch_ins.size());

        //sum kernel values and get decision values
        SAFE_KERNEL_LAUNCH(kernel_sum_kernel_values, kernel_values.device_data(), batch_ins.size(), sv.size(),
                           1, sv_index.device_data(), coef.device_data(), sv_start.device_data(),
                           sv_count.device_data(), rho.device_data(), dec_values.device_data());

        for (int i = 0; i < batch_ins.size(); ++i) {
            predict_y.push_back(dec_values[i]);
        }
        batch_start += batch_size;
    }
    return predict_y;
}

void SvmModel::record_model(const SyncData<real> &alpha, const SyncData<int> &y) {
    int n_sv = 0;
    for (int i = 0; i < n_instances; ++i) {
        if (alpha[i] != 0) {
            coef.push_back(alpha[i]);
            sv_index.push_back(sv.size());
            sv.push_back(dataSet.instances()[i]);
            n_sv++;
        }
    }
    LOG(INFO) << "RHO = " << rho;
    LOG(INFO) << "#SV = " << n_sv;
}
