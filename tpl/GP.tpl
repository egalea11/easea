\TEMPLATE_START
#ifdef WIN32
#define _CRT_SECURE_NO_WARNINGS
#pragma comment(lib, "libEasea.lib")
#endif
/**
 This is program entry for TreeGP template for EASEA

*/

\ANALYSE_PARAMETERS
#include <stdlib.h>
#include <iostream>
#include <time.h>
#include "COptionParser.h"
#include "CRandomGenerator.h"
#include "CEvolutionaryAlgorithm.h"
#include "global.h"
#include "EASEAIndividual.hpp"

using namespace std;

/** Global variables for the whole algorithm */
CIndividual** pPopulation = NULL;
CIndividual*  bBest = NULL;
float* pEZ_MUT_PROB = NULL;
float* pEZ_XOVER_PROB = NULL;
unsigned *EZ_NB_GEN;
unsigned *EZ_current_generation;
CEvolutionaryAlgorithm* EA;



\ANALYSE_GP_OPCODE


int main(int argc, char** argv){


	parseArguments("EASEA.prm",argc,argv);

	ParametersImpl p;
	p.setDefaultParameters(argc,argv);
	CEvolutionaryAlgorithm* ea = p.newEvolutionaryAlgorithm();

	EA = ea;

	EASEAInit(argc,argv);

	CPopulation* pop = ea->getPopulation();

	ea->runEvolutionaryLoop();

	EASEAFinal(pop);

	delete pop;


#ifdef WIN32
	system("pause");
#endif
	return 0;
}

\START_CUDA_GENOME_CU_TPL
#ifdef WIN32
#define _CRT_SECURE_NO_WARNINGS
#pragma comment(lib, "libEasea.lib")
#endif

#include <string.h>
#include <fstream>
#ifndef WIN32
#include <sys/time.h>
#else
#include <time.h>
#endif
#include "CRandomGenerator.h"
#include "CPopulation.h"
#include "COptionParser.h"
#include "CStoppingCriterion.h"
#include "CEvolutionaryAlgorithm.h"
#include "global.h"
#include "CIndividual.h"
#include "CCuda.h"
#include "CGPNode.h"
#include <iostream>
#include <sstream>

unsigned gNO_FITNESS_CASES=0;

unsigned aborded_crossover;
float* input_k;
float* output_k;
int* indexes_k;
float* progs_k;
float* results_k;
int* hits_k;

using namespace std;

#include "EASEAIndividual.hpp"
bool INSTEAD_EVAL_STEP = false;

int fitnessCasesSetLength;


float** inputs;
float* outputs;
int* indexes;
int* hits;
float* results;
float* progs;

CRandomGenerator* globalRandomGenerator;
extern CEvolutionaryAlgorithm* EA;
#define CUDA_GP_TPL
#define GROW_FULL_RATIO 0.5

unsigned evaluation_threads_status;

#define NUMTHREAD2 128
#define MAX_STACK 50
#define LOGNUMTHREAD2 7

#define HIT_LEVEL  0.01f
#define PROBABLY_ZERO  1.11E-15f
#define BIG_NUMBER 1.0E15f

/* Insert declarations about opcodes*/
\INSERT_GP_OPCODE_DECL

\INSERT_USER_DECLARATIONS

\INSERT_USER_FUNCTIONS

float recEval(GPNode* root, float* input) {
  float OP1=0, OP2= 0, RESULT = 0;
  if( opArity[root->opCode]>=1) OP1 = recEval(root->children[0],input);
  if( opArity[root->opCode]>=2) OP2 = recEval(root->children[1],input);
  switch( root->opCode ){
\INSERT_GP_CPU_SWITCH
  default:
    fprintf(stderr,"error unknown terminal opcode %d\n",root->opCode);
    exit(-1);
  }
  return RESULT;
}

void simple_mutator(IndividualImpl* Genome){

  // Cassical  mutation
  // select a node
  int mutationPointChildId = 0;
  int mutationPointDepth = 0;
  GPNode* mutationPointParent = selectNode(Genome->root, &mutationPointChildId, &mutationPointDepth);
  
  
  if( !mutationPointParent ){
    mutationPointParent = Genome->root;
    mutationPointDepth = 0;
  }
  delete mutationPointParent->children[mutationPointChildId] ;
  mutationPointParent->children[mutationPointChildId] =
    construction_method( VAR_LEN+1, OPCODE_SIZE , 1, TREE_DEPTH_MAX-mutationPointDepth ,0,opArity,OP_ERC);
}


/**
   This function handles printing of tree.
   Every node is identify by its address, in memory,
   and labeled by the actual opCode.

   On our architecture (64bits, ubuntu 8.04 and gcc-4.3.2)
   the long int variable is sufficient to store the address
   without any warning.
 */
void toDotFile_r(GPNode* root, FILE* outputFile){
  if( root->opCode==OP_ERC )
    fprintf(outputFile," %ld [label=\"%s : %f\"];\n", (long int)root, opCodeName[(int)root->opCode],
	    root->erc_value);
 else
   fprintf(outputFile," %ld [label=\"%s\"];\n", (long int)root, opCodeName[(int)root->opCode]);
  
  for( int i=0 ; i<opArity[root->opCode] ; i++ ){
    if( root->children[i] ){
      fprintf(outputFile,"%ld -> %ld;\n", (long int)root, (long int)root->children[i]);
      toDotFile_r( root->children[i] , outputFile);
    }
  }
}

void toString_r(GPNode* root) {

	std::cout << '(';
	if (opArity[root->opCode] == 2) {
		toString_r(root->children[0]);
		std::cout << ' ';
		std::cout << opCodeName[(int)root->opCode];
		std::cout << ' ';
		toString_r(root->children[1]);
	} else {
		if (root->opCode == OP_ERC) {
			std::cout << root->erc_value;
		} else {
			std::cout << opCodeName[(int)root->opCode];
		}
		for (int i = 0; i < opArity[root->opCode]; ++i) {
			if (root->children[i]) {
				toString_r(root->children[i]);
				if (i < opArity[root->opCode] - 1) {
					std::cout << ' ';
				}
			}
		}
	}
	std::cout << ')';

	return;
}

void toString(GPNode* root) {
	
	toString_r(root);
	std::cout << std::endl;

	return;
}

/**
   This function prints a tree in dot (graphviz format).
   This is the entry point for the print operation. (see toDotFile_r,
   for the actual function)

   @arg root : set of trees, same type than in a individual.
   @arg baseFileName : base of filename for the output file.
   @arg treeId : the id of the tree to print, in the given set.
 */
void toDotFile(GPNode* root, const char* baseFileName, int treeId){
  std::ostringstream oss;
  oss << baseFileName << "-" << treeId << ".gv";

  FILE* outputFile = fopen(oss.str().c_str(),"w");
  if( !outputFile ){
    perror("Opening file for outputing dot representation ");
    printf("%s\n",oss.str().c_str());
    exit(-1);
  }

  fprintf(outputFile,"digraph trees {\n");
  if(root)
    toDotFile_r( root, outputFile);
  fprintf(outputFile,"}\n");
  fclose(outputFile);
}


void simpleCrossOver(IndividualImpl& p1, IndividualImpl& p2, IndividualImpl& c){
  int depthP1 = depthOfTree(p1.root);
  int depthP2 = depthOfTree(p2.root);

  int nbNodeP1 = enumTreeNodes(p1.root);
   int nbNodeP2 = enumTreeNodes(p2.root);

  int stockPointChildId=0;
  int graftPointChildId=0;

  bool stockCouldBeTerminal = globalRandomGenerator->tossCoin(0.1);
  bool graftCouldBeTerminal = globalRandomGenerator->tossCoin(0.1);

  int childrenDepth = 0, Np1 = 0 , Np2 = 0;
  GPNode* stockParentNode = NULL;
  GPNode* graftParentNode = NULL;

  unsigned tries = 0;
  do{
  choose_node:
    
    tries++;
    if( tries>=10 ){
      aborded_crossover++;
      Np1=0;
      Np2=0;
      break;
    }

    if( nbNodeP1<2 ) Np1=0;
    else Np1 = (int)globalRandomGenerator->random((int)0,(int)nbNodeP1);
    if( nbNodeP2<2 ) Np2=0;
    else Np2 = (int)globalRandomGenerator->random((int)0,(int)nbNodeP2);


    
    if( Np1!=0 ) stockParentNode = pickNthNode(c.root, MIN(Np1,nbNodeP1) ,&stockPointChildId,TREE_DEPTH_MAX,MAX_ARITY);
    if( Np2!=0 ) graftParentNode = pickNthNode(p2.root, MIN(Np2,nbNodeP1) ,&graftPointChildId,TREE_DEPTH_MAX,MAX_ARITY);

    // is the stock and the graft an authorized type of node (leaf or inner-node)
    if( Np1 && !stockCouldBeTerminal && opArity[stockParentNode->children[stockPointChildId]->opCode]==0 ) goto choose_node;
    if( Np2 && !graftCouldBeTerminal && opArity[graftParentNode->children[graftPointChildId]->opCode]==0 ) goto choose_node;
    
    if( Np2 && Np1)
      childrenDepth = depthOfNode(c.root,stockParentNode)+depthOfTree(graftParentNode->children[graftPointChildId]);
    else if( Np1 ) childrenDepth = depthOfNode(c.root,stockParentNode)+depthP1;
    else if( Np2 ) childrenDepth = depthOfTree(graftParentNode->children[graftPointChildId]);
    else childrenDepth = depthP2;
    
  }while( childrenDepth>TREE_DEPTH_MAX );

  
  if( Np1 && Np2 ){
    delete stockParentNode->children[stockPointChildId];
    stockParentNode->children[stockPointChildId] = graftParentNode->children[graftPointChildId];
    graftParentNode->children[graftPointChildId] = NULL;
  }
  else if( Np1 ){ // && Np2==NULL
    // We want to use the root of the parent 2 as graft
    delete stockParentNode->children[stockPointChildId];
    stockParentNode->children[stockPointChildId] = p2.root;
    p2.root = NULL;
  }else if( Np2 ){ // && Np1==NULL
    // We want to use the root of the parent 1 as stock
    delete c.root;
    c.root = graftParentNode->children[graftPointChildId];
    graftParentNode->children[graftPointChildId] = NULL;
  }else{
    // We want to switch root nodes between parents
    delete c.root;
    c.root  = p2.root;
    p2.root = NULL;
  }
}






float IndividualImpl::evaluate(){
  float ERROR; 
 float sum = 0;
  \INSERT_GENOME_EVAL_HDR

   for( int i=0 ; i<gNO_FITNESS_CASES ; i++ ){
     float EVOLVED_VALUE = recEval(this->root,inputs[i]);
     \INSERT_GENOME_EVAL_BDY
     sum += ERROR;
   }
  this->valid = true;
  ERROR = sum;
  \INSERT_GENOME_EVAL_FTR    
}






\ANALYSE_USER_CLASSES

\INSERT_USER_CLASSES

\INSERT_INITIALISATION_FUNCTION
\INSERT_FINALIZATION_FUNCTION

void IndividualImpl::boundChecking(){
	\INSERT_BOUND_CHECKING
}

string IndividualImpl::serialize(){
    ostringstream AESAE_Line(ios_base::app);
    \GENOME_SERIAL
    AESAE_Line << this->fitness;
    return AESAE_Line.str();
}

void IndividualImpl::deserialize(string Line){
    istringstream AESAE_Line(Line);
    string line;
    \GENOME_DESERIAL
    AESAE_Line >> this->fitness;
    this->valid=true;
}

void evale_pop_chunk(CIndividual** population, int popSize){
  \INSTEAD_EVAL_FUNCTION
}


void EASEAInit(int argc, char** argv){

  int maxPopSize = MAX(EA->population->parentPopulationSize,EA->population->offspringPopulationSize);


  \INSERT_INIT_FCT_CALL

  // load data from csv file.
  cout<<"Before everything else function called "<<endl;
  cout << "number of point in fitness cases set : " << gNO_FITNESS_CASES << endl;

  float* inputs_f = NULL;

  flattenDatas2D(inputs,gNO_FITNESS_CASES,VAR_LEN,&inputs_f);

  indexes = new int[maxPopSize];
  hits    = new int[maxPopSize];
  results = new float[maxPopSize];
  progs   = new float[MAX_PROGS_SIZE];
  
  INSTEAD_EVAL_STEP=false;
}

void EASEAFinal(CPopulation* pop){
  \INSERT_FINALIZATION_FCT_CALL;

  // not sure that the population is sorted now. So lets do another time (or check in the code;))
  // and dump the best individual in a graphviz file.
  //population->sortParentPopulation();
  //toDotFile( ((IndividualImpl*)population->parents[0])->root[0], "best-of-run",0);
  
  // delete some global arrays
  delete[] indexes; delete[] hits;
  delete[] results; delete[] progs;
  
  //free_gpu();
  //free_data();
}

void AESAEBeginningGenerationFunction(CEvolutionaryAlgorithm* evolutionaryAlgorithm){
	\INSERT_BEGIN_GENERATION_FUNCTION
}

void AESAEEndGenerationFunction(CEvolutionaryAlgorithm* evolutionaryAlgorithm){
	\INSERT_END_GENERATION_FUNCTION
}

void AESAEGenerationFunctionBeforeReplacement(CEvolutionaryAlgorithm* evolutionaryAlgorithm){
	\INSERT_GENERATION_FUNCTION_BEFORE_REPLACEMENT
}


IndividualImpl::IndividualImpl() : CIndividual() {
  \GENOME_CTOR 
  \INSERT_EO_INITIALISER
  valid = false;
}

CIndividual* IndividualImpl::clone(){
	return new IndividualImpl(*this);
}

IndividualImpl::~IndividualImpl(){
  \GENOME_DTOR
}


IndividualImpl::IndividualImpl(const IndividualImpl& genome){

  // ********************
  // Problem specific part
  \COPY_CTOR


  // ********************
  // Generic part
  this->valid = genome.valid;
  this->fitness = genome.fitness;
}


CIndividual* IndividualImpl::crossover(CIndividual** ps){
	// ********************
	// Generic part


	IndividualImpl** tmp = (IndividualImpl**)ps;
	IndividualImpl parent1(*this);
	IndividualImpl parent2(*tmp[0]);
	IndividualImpl child(*this);

	// ********************
	// Problem specific part
  	\INSERT_CROSSOVER


	child.valid = false;


	return new IndividualImpl(child);
}


void IndividualImpl::printOn(std::ostream& os) const{
	\INSERT_DISPLAY
}

std::ostream& operator << (std::ostream& O, const IndividualImpl& B)
{
  // ********************
  // Problem specific part
  O << "\nIndividualImpl : "<< std::endl;
  O << "\t\t\t";
  B.printOn(O);

  if( B.valid ) O << "\t\t\tfitness : " << B.fitness;
  else O << "fitness is not yet computed" << std::endl;
  return O;
}


unsigned IndividualImpl::mutate( float pMutationPerGene ){
  this->valid=false;


  // ********************
  // Problem specific part
  \INSERT_MUTATOR
}




void ParametersImpl::setDefaultParameters(int argc, char** argv){

	seed = setVariable("seed",(int)time(0));
	globalRandomGenerator = new CRandomGenerator(seed);
	this->randomGenerator = globalRandomGenerator;


	this->minimizing = \MINIMAXI;
	this->nbGen = setVariable("nbGen",(int)\NB_GEN);

	selectionOperator = getSelectionOperator(setVariable("selectionOperator","\SELECTOR_OPERATOR"), this->minimizing, globalRandomGenerator);
	replacementOperator = getSelectionOperator(setVariable("reduceFinalOperator","\RED_FINAL_OPERATOR"),this->minimizing, globalRandomGenerator);
	parentReductionOperator = getSelectionOperator(setVariable("reduceParentsOperator","\RED_PAR_OPERATOR"),this->minimizing, globalRandomGenerator);
	offspringReductionOperator = getSelectionOperator(setVariable("reduceOffspringOperator","\RED_OFF_OPERATOR"),this->minimizing, globalRandomGenerator);
	selectionPressure = setVariable("selectionPressure",(float)\SELECT_PRM);
	replacementPressure = setVariable("reduceFinalPressure",(float)\RED_FINAL_PRM);
	parentReductionPressure = setVariable("reduceParentsPressure",(float)\RED_PAR_PRM);
	offspringReductionPressure = setVariable("reduceOffspringPressure",(float)\RED_OFF_PRM);
	pCrossover = \XOVER_PROB;
	pMutation = \MUT_PROB;
	pMutationPerGene = 0.05;

	parentPopulationSize = setVariable("popSize",(int)\POP_SIZE);
	offspringPopulationSize = setVariable("nbOffspring",(int)\OFF_SIZE);


	parentReductionSize = setReductionSizes(parentPopulationSize, setVariable("survivingParents",(float)\SURV_PAR_SIZE));
	offspringReductionSize = setReductionSizes(offspringPopulationSize, setVariable("survivingOffspring",(float)\SURV_OFF_SIZE));

	this->elitSize = setVariable("elite",(int)\ELITE_SIZE);
	this->strongElitism = setVariable("eliteType",(int)\ELITISM);

	if((this->parentReductionSize + this->offspringReductionSize) < this->parentPopulationSize){
		printf("*WARNING* parentReductionSize + offspringReductionSize < parentPopulationSize\n");
		printf("*WARNING* change Sizes in .prm or .ez\n");
		printf("EXITING\n");
		exit(1);	
	} 
	if((this->parentPopulationSize-this->parentReductionSize)>this->parentPopulationSize-this->elitSize){
		printf("*WARNING* parentPopulationSize - parentReductionSize > parentPopulationSize - elitSize\n");
		printf("*WARNING* change Sizes in .prm or .ez\n");
		printf("EXITING\n");
		exit(1);	
	} 
	if(!this->strongElitism && ((this->offspringPopulationSize - this->offspringReductionSize)>this->offspringPopulationSize-this->elitSize)){
		printf("*WARNING* offspringPopulationSize - offspringReductionSize > offspringPopulationSize - elitSize\n");
		printf("*WARNING* change Sizes in .prm or .ez\n");
		printf("EXITING\n");
		exit(1);	
	} 
	

	/*
	 * The reduction is set to true if reductionSize (parent or offspring) is set to a size less than the
	 * populationSize. The reduction size is set to populationSize by default
	 */
	if(offspringReductionSize<offspringPopulationSize) offspringReduction = true;
	else offspringReduction = false;

	if(parentReductionSize<parentPopulationSize) parentReduction = true;
	else parentReduction = false;

	cout << "Parent red " << parentReduction << " " << parentReductionSize << "/"<< parentPopulationSize << endl;
	cout << "Parent red " << offspringReduction << " " << offspringReductionSize << "/" << offspringPopulationSize << endl;

	generationalCriterion = new CGenerationalCriterion(setVariable("nbGen",(int)\NB_GEN));
	controlCStopingCriterion = new CControlCStopingCriterion();
	timeCriterion = new CTimeCriterion(setVariable("timeLimit",\TIME_LIMIT));
	
	this->optimise = 0;


	this->printStats = setVariable("printStats",\PRINT_STATS);
	this->generateCSVFile = setVariable("generateCSVFile",\GENERATE_CSV_FILE);
	this->generateGnuplotScript = setVariable("generateGnuplotScript",\GENERATE_GNUPLOT_SCRIPT);
	this->generateRScript = setVariable("generateRScript",\GENERATE_R_SCRIPT);
	this->plotStats = setVariable("plotStats",\PLOT_STATS);
	this->printInitialPopulation = setVariable("printInitialPopulation",0);
	this->printFinalPopulation = setVariable("printFinalPopulation",0);
        this->savePopulation = setVariable("savePopulation",\SAVE_POPULATION);
        this->startFromFile = setVariable("startFromFile",\START_FROM_FILE);

	this->outputFilename = (char*)"EASEA";
	this->plotOutputFilename = (char*)"EASEA.png";

        this->remoteIslandModel = setVariable("remoteIslandModel",\REMOTE_ISLAND_MODEL);
        this->ipFile = (char*)setVariable("ipFile","\IP_FILE").c_str();
        this->migrationProbability = setVariable("migrationProbability",(float)\MIGRATION_PROBABILITY);
	
	gNO_FITNESS_CASES = setVariable("fcSize",\FC_SIZE);
}

CEvolutionaryAlgorithm* ParametersImpl::newEvolutionaryAlgorithm(){

	pEZ_MUT_PROB = &pMutationPerGene;
	pEZ_XOVER_PROB = &pCrossover;
	EZ_NB_GEN = (unsigned*)setVariable("nbGen",\NB_GEN);
	EZ_current_generation=0;

	CEvolutionaryAlgorithm* ea = new EvolutionaryAlgorithmImpl(this);
	generationalCriterion->setCounterEa(ea->getCurrentGenerationPtr());
	ea->addStoppingCriterion(generationalCriterion);
	ea->addStoppingCriterion(controlCStopingCriterion);
	ea->addStoppingCriterion(timeCriterion);	

	EZ_NB_GEN=((CGenerationalCriterion*)ea->stoppingCriteria[0])->getGenerationalLimit();
	EZ_current_generation=&(ea->currentGeneration);

	 return ea;
}

void EvolutionaryAlgorithmImpl::initializeParentPopulation(){
        if(this->params->startFromFile){
          ifstream AESAE_File("EASEA.pop");
          string AESAE_Line;
          for( unsigned int i=0 ; i< this->params->parentPopulationSize ; i++){
                  getline(AESAE_File, AESAE_Line);
                  this->population->addIndividualParentPopulation(new IndividualImpl(),i);
                  ((IndividualImpl*)this->population->parents[i])->deserialize(AESAE_Line);
          }

        }
        else{
          for( unsigned int i=0 ; i< this->params->parentPopulationSize ; i++){
                  this->population->addIndividualParentPopulation(new IndividualImpl(),i);
          }
        }
        this->population->actualParentPopulationSize = this->params->parentPopulationSize;
}


EvolutionaryAlgorithmImpl::EvolutionaryAlgorithmImpl(Parameters* params) : CEvolutionaryAlgorithm(params){
	;
}

EvolutionaryAlgorithmImpl::~EvolutionaryAlgorithmImpl(){
  
}

\START_CUDA_GENOME_H_TPL

#ifndef PROBLEM_DEP_H
#define PROBLEM_DEP_H

extern unsigned gNO_FITNESS_CASES;

\INSERT_GP_PARAMETERS

//#include "CRandomGenerator.h"
#include <stdlib.h>
#include <iostream>
#include <CIndividual.h>
#include <Parameters.h>
#include <CGPNode.h>
class CRandomGenerator;
class CSelectionOperator;
class CGenerationalCriterion;
class CEvolutionaryAlgorithm;
class CPopulation;
class Parameters;

\INSERT_USER_CLASSES_DEFINITIONS

class IndividualImpl : public CIndividual {

public: // in EASEA the genome is public (for user functions,...)
	// Class members
  	\INSERT_GENOME


public:
	IndividualImpl();
	IndividualImpl(const IndividualImpl& indiv);
	virtual ~IndividualImpl();
	float evaluate();
	static unsigned getCrossoverArrity(){ return 2; }
	float getFitness(){ return this->fitness; }
	CIndividual* crossover(CIndividual** p2);
	void printOn(std::ostream& O) const;
	CIndividual* clone();

	unsigned mutate(float pMutationPerGene);

	void boundChecking();
	
	string serialize();
	void deserialize(string AESAE_Line);


	friend std::ostream& operator << (std::ostream& O, const IndividualImpl& B) ;
	void initRandomGenerator(CRandomGenerator* rg){ IndividualImpl::rg = rg;}

};


class ParametersImpl : public Parameters {
public:
	void setDefaultParameters(int argc, char** argv);
	CEvolutionaryAlgorithm* newEvolutionaryAlgorithm();
};

/**
 * @TODO ces functions devraient s'appeler weierstrassInit, weierstrassFinal etc... (en gros EASEAFinal dans le tpl).
 *
 */

void EASEAInit(int argc, char** argv);
void EASEAFinal(CPopulation* pop);
void EASEABeginningGenerationFunction(CEvolutionaryAlgorithm* evolutionaryAlgorithm);
void EASEAEndGenerationFunction(CEvolutionaryAlgorithm* evolutionaryAlgorithm);
void EASEAGenerationFunctionBeforeReplacement(CEvolutionaryAlgorithm* evolutionaryAlgorithm);


class EvolutionaryAlgorithmImpl: public CEvolutionaryAlgorithm {
public:
	EvolutionaryAlgorithmImpl(Parameters* params);
	virtual ~EvolutionaryAlgorithmImpl();
	void initializeParentPopulation();
};

#endif /* PROBLEM_DEP_H */

\START_CUDA_MAKEFILE_TPL

CXX=g++
EASEALIB_PATH=\EZ_PATHlibeasea/
CXXFLAGS =  -g  -I$(EASEALIB_PATH)include -I$(EZ_PATH)boost
OBJS = EASEA.o EASEAIndividual.o 
LIBS = 
TARGET = EASEA

\INSERT_MAKEFILE_OPTION#END OF USER MAKEFILE OPTIONS

$(TARGET):	$(OBJS)
	$(CXX) -o $(TARGET) $(OBJS) $(LIBS) -g $(EASEALIB_PATH)libeasea.a $(EZ_PATH)boost/program_options.a -lpthread

%.o:%.cpp
	$(CXX) -c $(CXXFLAGS) $^ $(CXX_OPT)

all:	$(TARGET)
clean:
	rm -f $(OBJS) $(TARGET)
easeaclean:
	rm -f $(TARGET) *.o *.cpp *.hpp EASEA.png EASEA.dat EASEA.prm EASEA.mak Makefile EASEA.vcproj EASEA.csv EASEA.r EASEA.plot

\START_VISUAL_TPL<?xml version="1.0" encoding="Windows-1252"?>
<VisualStudioProject
	ProjectType="Visual C++"
	Version="9,00"
	Name="EASEA"
	ProjectGUID="{E73D5A89-F262-4F0E-A876-3CF86175BC30}"
	RootNamespace="EASEA"
	Keyword="Win32Proj"
	TargetFrameworkVersion="196613"
	>
	<Platforms>
		<Platform
			Name="Win32"
		/>
	</Platforms>
	<ToolFiles>
	</ToolFiles>
	<Configurations>
		<Configuration
			Name="Release|Win32"
			OutputDirectory="$(SolutionDir)"
			IntermediateDirectory="$(ConfigurationName)"
			ConfigurationType="1"
			CharacterSet="1"
			WholeProgramOptimization="1"
			>
			<Tool
				Name="VCPreBuildEventTool"
			/>
			<Tool
				Name="VCCustomBuildTool"
			/>
			<Tool
				Name="VCXMLDataGeneratorTool"
			/>
			<Tool
				Name="VCWebServiceProxyGeneratorTool"
			/>
			<Tool
				Name="VCMIDLTool"
			/>
			<Tool
				Name="VCCLCompilerTool"
				Optimization="2"
				EnableIntrinsicFunctions="true"
				AdditionalIncludeDirectories="&quot;\EZ_PATHlibEasea&quot;"
				PreprocessorDefinitions="WIN32;NDEBUG;_CONSOLE"
				RuntimeLibrary="2"
				EnableFunctionLevelLinking="true"
				UsePrecompiledHeader="0"
				WarningLevel="3"
				DebugInformationFormat="3"
			/>
			<Tool
				Name="VCManagedResourceCompilerTool"
			/>
			<Tool
				Name="VCResourceCompilerTool"
			/>
			<Tool
				Name="VCPreLinkEventTool"
			/>
			<Tool
				Name="VCLinkerTool"
				LinkIncremental="1"
				AdditionalLibraryDirectories="&quot;\EZ_PATHlibEasea&quot;"
				GenerateDebugInformation="true"
				SubSystem="1"
				OptimizeReferences="2"
				EnableCOMDATFolding="2"
				TargetMachine="1"
			/>
			<Tool
				Name="VCALinkTool"
			/>
			<Tool
				Name="VCManifestTool"
			/>
			<Tool
				Name="VCXDCMakeTool"
			/>
			<Tool
				Name="VCBscMakeTool"
			/>
			<Tool
				Name="VCFxCopTool"
			/>
			<Tool
				Name="VCAppVerifierTool"
			/>
			<Tool
				Name="VCPostBuildEventTool"
			/>
		</Configuration>
	</Configurations>
	<References>
	</References>
	<Files>
		<Filter
			Name="Source Files"
			Filter="cpp;c;cc;cxx;def;odl;idl;hpj;bat;asm;asmx"
			UniqueIdentifier="{4FC737F1-C7A5-4376-A066-2A32D752A2FF}"
			>
			<File
				RelativePath=".\EASEA.cpp"
				>
			</File>
			<File
				RelativePath=".\EASEAIndividual.cpp"
				>
			</File>
		</Filter>
		<Filter
			Name="Header Files"
			Filter="h;hpp;hxx;hm;inl;inc;xsd"
			UniqueIdentifier="{93995380-89BD-4b04-88EB-625FBE52EBFB}"
			>
			<File
				RelativePath=".\EASEAIndividual.hpp"
				>
			</File>
		</Filter>
		<Filter
			Name="Resource Files"
			Filter="rc;ico;cur;bmp;dlg;rc2;rct;bin;rgs;gif;jpg;jpeg;jpe;resx;tiff;tif;png;wav"
			UniqueIdentifier="{67DA6AB6-F800-4c08-8B7A-83BB121AAD01}"
			>
		</Filter>
	</Files>
	<Globals>
	</Globals>
</VisualStudioProject>

\START_EO_PARAM_TPL#****************************************
#                                         
#  EASEA.prm
#                                         
#  Parameter file generated by STD.tpl AESAE v1.0
#                                         
#***************************************
# --seed=0   # -S : Random number seed. It is possible to give a specific seed.
--fcSize=\FC_SIZE

######    Evolution Engine    ######
--popSize=\POP_SIZE # -P : Population Size
--nbOffspring=\OFF_SIZE # -O : Nb of offspring (percentage or absolute)

######	  Stopping Criterions    #####
--nbGen=\NB_GEN #Nb of generations
--timeLimit=\TIME_LIMIT # Time Limit: desactivate with (0) (in Seconds)

######    Evolution Engine / Replacement    ######
--elite=\ELITE_SIZE  # Nb of elite parents (absolute)
--eliteType=\ELITISM # Strong (1) or weak (0) elitism (set elite to 0 for none)
--survivingParents=\SURV_PAR_SIZE # Nb of surviving parents (percentage or absolute)
--survivingOffspring=\SURV_OFF_SIZE  # Nb of surviving offspring (percentage or absolute)
--selectionOperator=\SELECTOR_OPERATOR # Selector: Deterministic, Tournament, Random, Roulette 
--selectionPressure=\SELECT_PRM
--reduceParentsOperator=\RED_PAR_OPERATOR 
--reduceParentsPressure=\RED_PAR_PRM
--reduceOffspringOperator=\RED_OFF_OPERATOR 
--reduceOffspringPressure=\RED_OFF_PRM
--reduceFinalOperator=\RED_FINAL_OPERATOR
--reduceFinalPressure=\RED_FINAL_PRM

#####	Stats Ouput 	#####
--printStats=\PRINT_STATS #print Stats to screen
--plotStats=\PLOT_STATS #plot Stats with gnuplot (requires Gnuplot)
--printInitialPopulation=0 #Print initial population
--printFinalPopulation=0 #Print final population
--generateCSV=\GENERATE_CSV_FILE
--generateGnuplotScript=\GENERATE_GNUPLOT_SCRIPT
--generateRScript=\GENERATE_R_SCRIPT

#### Population save    ####
--savePopulation=\SAVE_POPULATION #save population to EASEA.pop file
--startFromFile=\START_FROM_FILE #start optimisation from EASEA.pop file

#### Remote Island Model ####
--remoteIslandModel=\REMOTE_ISLAND_MODEL #To initialize communications with remote AESAE's
--ipFile=\IP_FILE
--migrationProbability=\MIGRATION_PROBABILITY #Probability to send an individual every generation

\TEMPLATE_END