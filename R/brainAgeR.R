#' brainAge
#'
#' Estimate brain age and related variable from input T1 MRI
#'
#' @param x input image
#' @param template input template, optional
#' @param model input deep model, optional
#' @param batch_size greater than 1 uses simulation to add variance in estimated values
#' @return data frame of predictions and the brain age model
#' @author Avants BB
#' @examples
#'
#' \dontrun{
#' myPredictions = brainAge( img, template, model )
#' }
#' @export brainAge
#' @importFrom stats rnorm
#' @importFrom ANTsRNet createResNetModel3D randomImageTransformAugmentation
brainAge <- function( x, template, model, batch_size = 8 ) {
  library( keras )
  if ( missing( template ) ) {
    templateFN = system.file("extdata", "template.nii.gz", package = "brainAgeR", mustWork = TRUE)
    }
  tardim = c( 192, 224, 192 )
  template = antsImageRead( templateFN ) %>%
    resampleImage( tardim , useVoxels=TRUE, interpType = 'linear' )
  templateSub = resampleImage( template, dim(template)/2,
            useVoxels=TRUE, interpType = 'linear' )

  avgimgfn1 = system.file("extdata", "avgImg.nii.gz", package = "brainAgeR", mustWork = TRUE)
  avgimgfn2 = system.file("extdata", "avgImg2.nii.gz", package = "brainAgeR", mustWork = TRUE)
  avgImg = antsImageRead( avgimgfn1 ) %>% antsCopyImageInfo2( template )
  avgImg2 = antsImageRead( avgimgfn2 ) %>% antsCopyImageInfo2( templateSub )

  meanMask = thresholdImage( x, 0.5 * mean( x ), Inf ) %>%
    morphology( "dilate", 3 ) %>% iMath("FillHoles")
  x = n4BiasFieldCorrection( x, meanMask, shrinkFactor = 4 )
  aff = antsRegistration( template, x, "Affine", verbose = F )
  imageAffSub = antsApplyTransforms( templateSub, x, aff$fwdtransforms,
            interpolator = c("linear") )

  getRandomBaseInd <- function( off = 10, patchWidth = 96 ) {
    baseInd = rep( NA, 3 )
    for ( k in 1:3 )
      baseInd[k]=sample( off:( fullDims[k] - patchWidth - off ) )[1]
    return( baseInd )
    }

    if ( missing( model ) ) {
      nclass = 6
      ncogs = 1
      modelFN = system.file("extdata", "resNet4LayerLR64Card64b.h5", package = "brainAgeR", mustWork = TRUE)
      inputImageSize = c( dim( template ),  2  )
      mdl <- ANTsRNet::createResNetModel3D(inputImageSize, numberOfClassificationLabels = 1000,
             layers = 1:4, residualBlockSchedule = c(3, 4, 6, 3),
             lowestResolution = 64, cardinality = 64, mode = "classification")
      layerName = as.character(
        mdl$layers[[length(mdl$layers)-1 ]]$name )
      idLayer <- layer_dense( get_layer(mdl, layerName )$output, nclass,
        activation='sigmoid' ) # 'softmax' )
      ageLayer <- layer_dense( get_layer(mdl, layerName )$output, ncogs, activation = 'linear' )
      sexLayer <- layer_dense( get_layer(mdl, layerName )$output, 1,
        activation = 'sigmoid' )
      ptch = 96
      patchShape = c( rep( ptch, 3 ) , 2 )
      inputPatch <- layer_input( patchShape )
      model <- keras_model( inputs = list( mdl$input, inputPatch ),
          outputs = list(
            idLayer,
            ageLayer,
            sexLayer ) )
      load_model_weights_hdf5( model, modelFN )
      }


  imageAff = antsApplyTransforms( template, x, aff$fwdtransforms,
        interpolator = c("linear") )
  imageAffSub = antsApplyTransforms( templateSub, x, aff$fwdtransforms,
        interpolator = c("linear") )
  fullDims = dim( imageAff )
  ptch = 96

  myAug3D <- function( img2, imgFull, batch_size = 1, sdAff = 0.0 ) {
        nc = 2
        X = array( dim = c( batch_size, dim( template ), nc ) )
        X2 = array( dim = c( batch_size, rep(ptch,3), nc ) )
        for ( ind in 1:batch_size ) {
          imgG = iMath( img2, "Normalize" )
          if ( all(   dim(imgG) == dim( avgImg2 ) ) ) {
            antsCopyImageInfo(avgImg2,  imgG )
            imgGdiff = imgG - avgImg2
          } else stop("dim(imgG) != dim( avgImg2 )")
          fullImage = iMath( imgFull, "Normalize" )
          if ( all(   dim(fullImage) == dim( avgImg ) ) )
            pdiff = fullImage - avgImg else stop("dim(fullImage) != dim( avgImg )")
          baseInd = getRandomBaseInd()
          topInd = baseInd + c( ptch, ptch, ptch ) - 1
          patch = cropIndices( fullImage, baseInd, topInd )
          pdiff = cropIndices( pdiff, baseInd, topInd )
          randy = ANTsRNet::randomImageTransformAugmentation( imgG,
            interpolator = c("linear","linear"),
            list( list( imgG, imgGdiff ) ), list( imgGdiff ), sdAffine = sdAff, n = 1 )
          imgG = randy$outputPredictorList[[1]][[1]] %>% iMath("Normalize")
          X[ ind, , , , 1 ] = as.array( imgG ) #  * 255 - 127.5
          X[ ind, , , , 2 ] = as.array( randy$outputPredictorList[[1]][[2]] ) # * 255 - 127.5
          X2[ind, , , , 1 ] = as.array( patch ) #  * 255 - 127.5
          X2[ind, , , , 2 ] = as.array( pdiff ) # * 255 - 127.5
        }
      return( list( X, X2 ) )
      }

  myX = myAug3D( imageAffSub, imageAff, batch_size = batch_size, sdAff = 0.01 )
  pp = predict( model, myX )
  sitenames = c("DLBS","HCP","IXI","NKIRockland","OAS1_","SALD" )
  mydf = data.frame(
    predictedAge = as.numeric( pp[[2]] ),
    predictedGender = as.numeric( pp[[3]] ) )
  siteDF = data.frame( matrix( pp[[1]], ncol = length( sitenames ) ) )
  names( siteDF ) = sitenames
  for ( k in 1:nrow( siteDF ) ) siteDF[k,] = siteDF[k,]/sum(siteDF[k,] )
  mydf <- cbind( mydf, siteDF )
  return( list( predictions=mydf, model=model ) )
}