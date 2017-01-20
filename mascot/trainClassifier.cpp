/*
 * testTrainer.cpp
 *
 *  Created on: 31/10/2013
 *      Author: Zeyi Wen
 */

#include <sys/time.h>
#include "../DataReader/LibsvmReaderSparse.h"
#include "../svm-shared/Cache/cache.h"
#include "../svm-shared/HessianIO/deviceHessianOnFly.h"
#include "../SharedUtility/Timer.h"
#include "../SharedUtility/KeyValue.h"
#include "trainClassifier.h"
#include "multiPredictor.h"

void trainSVM(SVMParam &param, string strTrainingFileName, int nNumofFeature, SvmModel &model, bool evaluteTrainingError) {
    vector<vector<KeyValue> > v_v_Instance;
    vector<int> v_nLabel;

    int nNumofInstance = 0;     //not used
    long long nNumofValue = 0;  //not used
    BaseLibSVMReader::GetDataInfo(strTrainingFileName, nNumofFeature, nNumofInstance, nNumofValue);
	LibSVMDataReader drHelper;
	drHelper.ReadLibSVMAsSparse(v_v_Instance, v_nLabel, strTrainingFileName, nNumofFeature);
    SvmProblem problem(v_v_Instance, nNumofFeature, v_nLabel);
    ACCUMULATE_TIME(trainingTimer, model.fit(problem, param))
    PRINT_TIME("training", trainingTimer)
    PRINT_TIME("pre-computation kernel",preComputeTimer)
    PRINT_TIME("iteration",iterationTimer)
    PRINT_TIME("2 instances selection",selectTimer)
    PRINT_TIME("kernel calculation",calculateKernelTimer)
    PRINT_TIME("alpha updating",updateAlphaTimer)
    PRINT_TIME("g value updating time",updateGTimer)
    //evaluate training error
    if (evaluteTrainingError == true) {
        printf("Computing training accuracy...\n");
        evaluate(model, v_v_Instance, v_nLabel);
    }
}

void evaluateSVMClassifier(SvmModel &model, string strTrainingFileName, int nNumofFeature) {
    vector<vector<KeyValue> > v_v_Instance;
    vector<int> v_nLabel;

    int nNumofInstance = 0;     //not used
    long long nNumofValue = 0;  //not used
    BaseLibSVMReader::GetDataInfo(strTrainingFileName, nNumofFeature, nNumofInstance, nNumofValue);
	LibSVMDataReader drHelper;
	drHelper.ReadLibSVMAsSparse(v_v_Instance, v_nLabel, strTrainingFileName, nNumofFeature);

    //evaluate testing error
    evaluate(model, v_v_Instance, v_nLabel);
}

/**
 * @brief: evaluate the svm model, given some labeled instances.
 */
void evaluate(SvmModel &model, vector<vector<KeyValue> > &v_v_Instance, vector<int> &v_nLabel)
{
    int batchSize = 2000;

    //create a miss labeling matrix for measuring the sub-classifier errors.
    model.missLabellingMatrix = vector<vector<int>(model.nrClass, 0)>(model.nrClass, 0);
    MultiPredictor predictor(model, model.param);

	clock_t start, finish;
    start = clock();
    int begin = 0;
    vector<int> predictLabels;
    while (begin < v_v_Instance.size()) {
    	//get a subset of instances
    	int end = min(begin + batchSize, (int) v_v_Instance.size());
        vector<vector<KeyValue> > samples(v_v_Instance.begin() + begin,
                                          v_v_Instance.begin() + end);
        vector<int> vLabel(v_nLabel.begin() + begin, v_nLabel.begin() + end);
        //predict labels for the subset of instances
        vector<int> predictLabelPart = predictor.predict(samples, vLabel);
        predictLabels.insert(predictLabels.end(), predictLabelPart.begin(), predictLabelPart.end());
        begin += batchSize;
    }
    finish = clock();
    int numOfCorrect = 0;
    for (int i = 0; i < v_v_Instance.size(); ++i) {
        if (predictLabels[i] == v_nLabel[i])
            numOfCorrect++;
    }
    printf("classifier accuracy = %.2f%%(%d/%d)\n", numOfCorrect / (float) v_v_Instance.size() * 100,
           numOfCorrect, (int) v_v_Instance.size());
    printf("prediction time elapsed: %.2fs\n", (float) (finish - start) / CLOCKS_PER_SEC);
}