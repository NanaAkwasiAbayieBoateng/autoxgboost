#' @title Fit and optimize a xgboost model.
#'
#' @description
#' An xgboost model is optimized based on a measure (see [\code{\link[mlr]{Measure}}]).
#' The bounds of the parameter in which the model is optimized, are defined by \code{\link{autoxgbparset}}.
#' For the optimization itself bayesian optimization with \pkg{mlrMBO} is used.
#' Without any specification of the control object, the optimizer runs for for 80 iterations or 1 hour, whatever happens first.
#' Both the parameter set and the control object can be set by the user.
#'
#'
#' @param task [\code{\link[mlr]{Task}}]\cr
#'   The task.
#' @param measure [\code{\link[mlr]{Measure}}]\cr
#'   Performance measure. If \code{NULL} \code{\link[mlr]{getDefaultMeasure}} is used.
#' @param control [\code{\link[mlrMBO]{MBOControl}}]\cr
#'   Control object for mbo. Specifies runtime behaviour.
#'   Default is to run for 160 iterations or 1 hour, whatever happens first.
#' @param par.set [\code{\link[ParamHelpers]{ParamSet}}]\cr
#'   Parameter set. Default is \code{\link{autoxgbparset}}.
#' @param max.nrounds [\code{integer(1)}]\cr
#'   Maximum number of allowed iterations. Default is \code{10^6}.
#' @param early.stopping.rounds [\code{integer(1L}]\cr
#'   After how many iterations without an improvement in the OOB error should be stopped?
#'   Default is 10.
#' @param build.final.model [\code{logical(1)}]\cr
#'   Should the best found model be fitted on the complete dataset?
#'   Default is \code{FALSE}.
#' @param early.stopping.fraction [\code{numeric(1)}]\cr
#'   What fraction of the data should be used for early stopping (i.e. as a validation set).
#'   Default is \code{4/5}.
#' @param design.size [\code{integer(1)}]\cr
#'   Size of the initial design. Default is \code{15L}.
#' @param impact.encoding.boundary [\code{integer(1)}]\cr
#'   Defines the threshold on how factor variables are handled. Factors with more levels than the \code{"impact.encoding.boundary"} get impact encoded (see \code{\link{createImpactFeatures}}) while factor variables with less or equal levels than the \code{"impact.encoding.boundary"} get dummy encoded.
#'   (see \code{\link[mlr]{createDummyFeatures}}). For \code{impact.encoding.boundary = 0L}, all factor variables get impact encoded while for \code{impact.encoding.boundary = Inf}, all of them get dummy encoded.
#'   Default is \code{10L}.
#' @param mbo.learner [\code{\link[mlr]{Learner}}]\cr
#'   Regression learner from mlr, which is used as a surrogate to model our fitness function.
#'   If \code{NULL} (default), the default learner is determined as described here: \link[mlrMBO]{mbo_default_learner}.
#' @param nthread [integer(1)]\cr
#'   Number of cores to use.
#'   If \code{NULL} (default), xgboost will determine internally how many cores to use.
#' @param tune.threshold [logical(1)]\cr
#'   Should thresholds be tuned? This has only an effect for classification, see \code{\link[mlr]{tuneThreshold}}.
#'   Default is \code{TRUE}.
#' @return \code{\link{AutoxgbResult}}
#' @export
#' @examples
#' \donttest{
#' iris.task = makeClassifTask(data = iris, target = "Species")
#' ctrl = makeMBOControl()
#' ctrl = setMBOControlTermination(ctrl, iters = 1L) #Speed up Tuning by only doing 1 iteration
#' res = autoxgboost(iris.task, control = ctrl, tune.threshold = FALSE)
#' res
#' }
autoxgboost = function(task, measure = NULL, control = NULL, par.set = NULL, max.nrounds = 10^6,
  early.stopping.rounds = 10L, early.stopping.fraction = 4/5, build.final.model = TRUE,
  design.size = 15L, impact.encoding.boundary = 10L, mbo.learner = NULL,
  nthread = NULL, tune.threshold = TRUE) {

  assertIntegerish(early.stopping.rounds, lower = 1L, len = 1L)
  assertNumeric(early.stopping.fraction, lower = 0, upper = 1, len = 1L)
  assertFlag(build.final.model)
  assertIntegerish(design.size, lower = 1, null.ok = FALSE)
  if (is.infinite(impact.encoding.boundary))
    impact.encoding.boundary = .Machine$integer.max
  assertIntegerish(impact.encoding.boundary, lower = 0, upper = Inf, len = 1L)
  assertIntegerish(nthread, lower = 1, null.ok = TRUE)
  assertFlag(tune.threshold)

  measure = coalesce(measure, getDefaultMeasure(task))
  if (is.null(control)) {
    control = makeMBOControl()
    control = setMBOControlTermination(control, iters = 160L, time.budget = 3600L)
  }

  par.set = coalesce(par.set, autoxgboost::autoxgbparset)
  tt = getTaskType(task)
  td = getTaskDesc(task)
  has.cat.feats = sum(td$n.feat[c("factors", "ordered")]) > 0
  pv = list()
  if (!is.null(nthread))
    pv$nthread = nthread

  rdesc = makeResampleDesc("Holdout", split = early.stopping.fraction)
  early.stopping.data =  makeResampleInstance(rdesc, task)$test.inds[[1]]

  if (tt == "classif") {

    predict.type = ifelse("req.prob" %in% measure$properties | tune.threshold, "prob", "response")
    if(length(td$class.levels) == 2) {
      objective = "binary:logistic"
      eval_metric = "error"
      par.set = c(par.set, makeParamSet(makeNumericParam("scale_pos_weight", lower = -10, upper = 10, trafo = function(x) 2^x)))
    } else {
      objective = "multi:softprob"
      eval_metric = "merror"
    }

    base.learner = makeLearner("classif.xgboost.earlystop", id = "classif.xgboost.earlystop", predict.type = predict.type,
      eval_metric = eval_metric, objective = objective, early_stopping_rounds = early.stopping.rounds,
      max.nrounds = max.nrounds, early.stopping.data = early.stopping.data, par.vals = pv)

  } else if (tt == "regr") {
    predict.type = NULL
    objective = "reg:linear"
    eval_metric = "rmse"

    base.learner = makeLearner("regr.xgboost.earlystop", id = "regr.xgboost.earlystop",
      eval_metric = eval_metric, objective = objective, early_stopping_rounds = early.stopping.rounds,
      max.nrounds = max.nrounds, early.stopping.data = early.stopping.data, par.vals = pv)

  } else {
    stop("Task must be regression or classification")
  }

  # factor encoding
  impact.cols = character(0L)
  dummy.cols = character(0L)

  if (has.cat.feats) {
    d = getTaskData(task, target.extra = TRUE)$data
    feat.cols = colnames(d)[vlapply(d, is.factor)]
    impact.cols = colnames(d)[vlapply(d, function(x) is.factor(x) && nlevels(x) > impact.encoding.boundary)]
    dummy.cols = setdiff(feat.cols, impact.cols)
    if (length(dummy.cols) > 0L)
      base.learner = makeDummyFeaturesWrapper(base.learner, cols = dummy.cols)
    if (length(impact.cols) > 0L) {
      base.learner = makeImpactFeaturesWrapper(base.learner, cols = impact.cols)
      par.set = c(par.set, autoxgboost::impactencodingparset)
    }
  }


  opt = smoof::makeSingleObjectiveFunction(name = "optimizeWrapper",
    fn = function(x) {

      lrn = setHyperPars(base.learner, par.vals = x)
      mod = train(lrn, task)
      test = subsetTask(task, subset = early.stopping.data)
      pred = predict(mod, test)
      nrounds = getBestIteration(mod)

      if (tune.threshold && tt == "classif") {
        tune.res = tuneThreshold(pred = pred, measure = measure)
        res = tune.res$perf
        attr(res, "extras") = list(nrounds = nrounds, .threshold = tune.res$th)
      } else {
        res = performance(pred, measure)
        attr(res, "extras") = list(nrounds = nrounds)
      }

      res

    }, par.set = par.set, noisy = TRUE, has.simple.signature = FALSE, minimize = measure$minimize)


  des = generateDesign(n = design.size, par.set)

  optim.result = mbo(fun = opt, control = control, design = des, learner = mbo.learner)

  lrn = buildFinalLearner(optim.result, objective, predict.type, par.set = par.set,
    dummy.cols = dummy.cols, impact.cols = impact.cols)

  mod = if(build.final.model) {
    train(lrn, task)
  } else {
    NULL
  }

  makeS3Obj("AutoxgbResult",
    optim.result = optim.result,
    final.learner = lrn,
    final.model = mod,
    measure = measure)

}
