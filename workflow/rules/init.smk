#########################################################
# IMPORT PYTHON LIBRARIES HERE
#########################################################
import sys
import os
import pandas as pd
import yaml
import pprint
import shutil
# import glob
# import shutil
pp = pprint.PrettyPrinter(indent=4)
#########################################################


#########################################################
# FILE-ACTION FUNCTIONS 
#########################################################
def check_existence(filename):
  if not os.path.exists(filename):
    exit("# File: %s does not exists!"%(filename))

def check_readaccess(filename):
  check_existence(filename)
  if not os.access(filename,os.R_OK):
    exit("# File: %s exists, but cannot be read!"%(filename))

def check_writeaccess(filename):
  check_existence(filename)
  if not os.access(filename,os.W_OK):
    exit("# File: %s exists, but cannot be read!"%(filename))

def get_file_size(filename):
    filename=filename.strip()
    if check_readaccess(filename):
        return os.stat(filename).st_size
#########################################################

#########################################################
# DEFINE CONFIG FILE AND READ IT
#########################################################
CONFIGFILE = str(workflow.overwrite_configfiles[0])

# set memory limit 
# used for sambamba sort, etc
MEMORYG="100G"

# read in various dirs from config file
WORKDIR=config['workdir']
RESULTSDIR=join(WORKDIR,"results")

# get scripts folder
try:
    SCRIPTSDIR = config["scriptsdir"]
except KeyError:
    SCRIPTSDIR = join(WORKDIR,"scripts")
check_existence(SCRIPTSDIR)

if not os.path.exists(join(WORKDIR,"fastqs")):
    os.mkdir(join(WORKDIR,"fastqs"))
if not os.path.exists(join(RESULTSDIR)):
    os.mkdir(join(RESULTSDIR))
for f in ["samplemanifest"]:
    check_readaccess(config[f])
#########################################################


#########################################################
# CREATE SAMPLE DATAFRAME
#########################################################
# each line in the samplemanifest is a replicate
# multiple replicates belong to a sample
# currently only 1,2,3 or 4 replicates per sample is supported
df=pd.read_csv(config["samplemanifest"],sep="\t",header=0)
df['replicateName']=df.apply(lambda row:row['sampleName']+"_"+str(row['replicateNumber']),axis=1)
REPLICATES = list(df.replicateName.unique())
replicateName2R1 = dict()
replicateName2R2 = dict()
for r in REPLICATES:
    r1=df[df['replicateName']==r].iloc[0].path_to_R1
    check_readaccess(r1)
    r1new=join(WORKDIR,"fastqs",r+".R1.fastq.gz")
    if not os.path.exists(r1new):
        os.symlink(r1,r1new)
    replicateName2R1[r]=r1new
    r2=df[df['replicateName']==r].iloc[0].path_to_R2
    check_readaccess(r2)
    r2new=join(WORKDIR,"fastqs",r+".R2.fastq.gz")
    if not os.path.exists(r2new):
        os.symlink(r2,r2new)
    replicateName2R2[r]=r2new


print("#"*100)
print("# Checking Sample Manifest...")
print("# Treatment Control combinations:")
process_replicates=[]
for i,t in enumerate(list(df[df['isControl']=="N"]['replicateName'].unique())):
    crow=df[df['replicateName']==t].iloc[0]
    c=crow.controlName+"_"+str(crow.controlReplicateNumber)
    if not c in REPLICATES:
        print("# Control NOT found for sampleName_replicateNumber:"+t)
        print("# "+config["samplemanifest"]+" has no entry for sample:"+crow.controlName+"  replicateNumber:"+crow.controlReplicateNumber)
        exit()        
    print("## "+str(i+1)+") "+t+"        "+c)
    process_replicates.extend([t,c])
process_replicates=list(set(process_replicates))
if len(process_replicates)!=len(REPLICATES):
    not_to_process = set(REPLICATES) - set(process_replicates)
    print("# Following replicates will not be processed as they are not part of any Treatment Control combination!")
    for i in not_to_process:
        print("# "+i)
    REPLICATES = process_replicates
print("# Read access to all fastq files in confirmed!")

#########################################################
# READ IN TOOLS REQUIRED BY PIPELINE
# THESE INCLUDE LIST OF BIOWULF MODULES (AND THEIR VERSIONS)
# MAY BE EMPTY IF ALL TOOLS ARE DOCKERIZED
#########################################################
## Load tools from YAML file
try:
    TOOLSYAML = config["tools"]
except KeyError:
    TOOLSYAML = join(WORKDIR,"tools.yaml")
check_readaccess(TOOLSYAML)
with open(TOOLSYAML) as f:
    TOOLS = yaml.safe_load(f)
#########################################################


#########################################################
# READ CLUSTER PER-RULE REQUIREMENTS
#########################################################

## Load cluster.json
try:
    CLUSTERYAML = config["CLUSTERYAML"]
except KeyError:
    CLUSTERYAML = join(WORKDIR,"cluster.yaml")
check_readaccess(CLUSTERYAML)
with open(CLUSTERYAML) as json_file:
    CLUSTER = yaml.safe_load(json_file)

## Create lambda functions to allow a way to insert read-in values
## as rule directives
getthreads=lambda rname:int(CLUSTER[rname]["threads"]) if rname in CLUSTER and "threads" in CLUSTER[rname] else int(CLUSTER["__default__"]["threads"])
getmemg=lambda rname:CLUSTER[rname]["mem"] if rname in CLUSTER and "mem" in CLUSTER[rname] else CLUSTER["__default__"]["mem"]
getmemG=lambda rname:getmemg(rname).replace("g","G")
#########################################################

#########################################################
# SET OTHER PIPELINE GLOBAL VARIABLES
#########################################################

print("# Pipeline Parameters:")
print("#"*100)
print("# Working dir :",WORKDIR)
print("# Results dir :",RESULTSDIR)
print("# Scripts dir :",SCRIPTSDIR)
print("# Config YAML :",CONFIGFILE)
print("# Sample Manifest :",config["samplemanifest"])
print("# Cluster YAML :",CLUSTERYAML)

GENOME = config["genome"]
GENOMEFA = config["reference"][GENOME]["fa"]
check_readaccess(GENOMEFA)

GENOMEBLACKLIST = config["reference"][GENOME]["blacklist"]
check_readaccess(GENOMEBLACKLIST)

SPIKED = config["spiked"]

if SPIKED == "Y":
    spikein_genome = config["spikein_genome"]
    SPIKED_GENOMEFA = config["spikein_reference"][spikein_genome]["fa"]
    check_readaccess(SPIKED_GENOMEFA)
else:
    SPIKED_GENOMEFA = ""

CREATE_REFERENCE = "N"
BOWTIE2_INDEX = join(WORKDIR,"bowtie2_index")
if not os.path.exists(BOWTIE2_INDEX):
    CREATE_REFERENCE = "Y"
else:
    if not os.path.exists(join(BOWTIE2_INDEX,"ref.json")):
        CREATE_REFERENCE = "Y"
    else:
        with open(join(BOWTIE2_INDEX,"ref.json")) as f:
            oldrefdata = yaml.safe_load(f)
        if oldrefdata["genome"] != GENOME or oldrefdata["genomefa"] != GENOMEFA or oldrefdata["blacklistbed"] != GENOMEBLACKLIST or oldrefdata["spiked"] != SPIKED or oldrefdata["spikein_genome"] != SPIKED_GENOMEFA :
            CREATE_REFERENCE = "Y"

if CREATE_REFERENCE == "Y":
    if os.path.exists(BOWTIE2_INDEX):
        shutil.rmtree(BOWTIE2_INDEX)
    os.mkdir(BOWTIE2_INDEX)
    os.symlink(GENOMEFA,join(BOWTIE2_INDEX,"genome.fa"))
    os.symlink(GENOMEBLACKLIST,join(BOWTIE2_INDEX,"genome.blacklist.bed"))
    if SPIKED == "Y":
        os.symlink(SPIKED_GENOMEFA,join(BOWTIE2_INDEX,"spikein.fa"))
    refdata = dict()
    refdata["genome"] = GENOME
    refdata["genomefa"] = GENOMEFA
    refdata["blacklistbed"] = GENOMEBLACKLIST
    refdata["spiked"] = SPIKED
    refdata["spikein_genome"] = SPIKED_GENOMEFA
# create json file and store in "tmp" until the reference is built
    os.mkdir(join(BOWTIE2_INDEX,"tmp"))
    with open(join(BOWTIE2_INDEX,"tmp","ref.json"), 'w') as file:
        dumped = yaml.dump(refdata, file)

GENOMEFA = join(BOWTIE2_INDEX,"genome.fa")
GENOMEBLACKLIST = join(BOWTIE2_INDEX,"genome.blacklist.bed")
if SPIKED == "Y":
    SPIKED_GENOMEFA = join(BOWTIE2_INDEX,"spikein.fa")
else:
    SPIKED_GENOMEFA = ""



# print("# Bowtie index dir:",INDEXDIR)

# GENOMEFILE=join(INDEXDIR,GENOME+".genome") # genome file is required by macs2 peak calling
# check_readaccess(GENOMEFILE)
# print("# Genome :",GENOME)
# print("# .genome :",GENOMEFILE)

# GENOMEFA=join(INDEXDIR,GENOME+".fa") # genome file is required by motif enrichment rule
# check_readaccess(GENOMEFA)
# print("# Genome fasta:",GENOMEFA)

# BLACKLISTFA=config[GENOME]['blacklistFa']
# check_readaccess(BLACKLISTFA)
# print("# Blacklist fasta:",BLACKLISTFA)

# QCDIR=join(RESULTSDIR,"QC")

# TSSBED=config[GENOME]["tssBed"]
# check_readaccess(TSSBED)
# print("# TSS BEDs :",TSSBED)

# HOMERMOTIF=config[GENOME]["homermotif"]
# check_readaccess(HOMERMOTIF)
# print("# HOMER motifs :",HOMERMOTIF)

# MEMEMOTIF=config[GENOME]["mememotif"]
# check_readaccess(MEMEMOTIF)
# print("# MEME motifs :",MEMEMOTIF)

# FASTQ_SCREEN_CONFIG=config["fastqscreen_config"]
# check_readaccess(FASTQ_SCREEN_CONFIG)
# print("# FQscreen config  :",FASTQ_SCREEN_CONFIG)

# try:
#     JACCARD_MIN_PEAKS=int(config["jaccard_min_peaks"])
# except KeyError:
#     JACCARD_MIN_PEAKS=100


# # FRIPEXTRA ... do you calculate extra Fraction of reads in blahblahblah
# FRIPEXTRA=True

# try:
#     DHSBED=config[GENOME]["fripextra"]["dhsbed"]
#     check_readaccess(DHSBED)
#     print("# DHS motifs :",DHSBED)
# except KeyError:
#     FRIPEXTRA=False
#     DHSBED=""
#     PROMOTERBED=""
#     ENHANCERBED=""

# try:
#     PROMOTERBED=config[GENOME]["fripextra"]["promoterbed"]
#     check_readaccess(PROMOTERBED)
#     print("# Promoter Bed:",PROMOTERBED)
# except KeyError:
#     FRIPEXTRA=False
#     DHSBED=""
#     PROMOTERBED=""
#     ENHANCERBED=""

# try:
#     ENHANCERBED=config[GENOME]["fripextra"]["enhancerbed"]
#     check_readaccess(ENHANCERBED)
#     print("# Enhancer Bed:",ENHANCERBED)
# except KeyError:
#     FRIPEXTRA=False
#     DHSBED=""
#     PROMOTERBED=""
#     ENHANCERBED=""

# try:
#     MULTIQCCONFIG=config['multiqc']['configfile']
#     check_readaccess(MULTIQCCONFIG)
#     print("# MultiQC configfile:",MULTIQCCONFIG)
#     MULTIQCEXTRAPARAMS=config['multiqc']['extraparams']   
# except KeyError:
#     MULTIQCCONFIG=""
#     MULTIQCEXTRAPARAMS=""
# print("#"*100)

#########################################################

rule create_reference:
    input: 
        genomefa = GENOMEFA,
        blacklist = GENOMEBLACKLIST,
        spikein = SPIKED_GENOMEFA
    output:
        bt2 = join(BOWTIE2_INDEX,"ref.1.bt2"),
        ref_len = join(BOWTIE2_INDEX,"ref.len"),
        spikein_len = join(BOWTIE2_INDEX,"spikein.len"),
        refjson = join(BOWTIE2_INDEX,"ref.json")
    params:
        bt2_base=join(BOWTIE2_INDEX,"ref")
    envmodules: 
        TOOLS["bowtie2"],
        TOOLS["samtools"],
        TOOLS["bedtools"],
    threads: getthreads("create_reference")
    shell:"""
set -exo pipefail
if [[ -d "/lscratch/$SLURM_JOB_ID" ]]; then 
    TMPDIR="/lscratch/$SLURM_JOB_ID"
else
    dirname=$(basename $(mktemp))
    TMPDIR="/dev/shm/$dirname"
    mkdir -p $TMPDIR
fi

if [[ "{input.spikein}" == "" ]];then
# there is NO SPIKEIN

    # create faidx for genome and spike fasta
    samtools faidx {input.genomefa}

    # mask genome fa with genome blacklist
    bedtools maskfasta -fi {input.genomefa} -bed {input.blacklist} -fo ${{TMPDIR}}/masked_genome.fa

    # build bowtie index
    bowtie2-build --threads {threads} ${{TMPDIR}}/masked_genome.fa {params.bt2_base}

    # create len files
    cut -f1,2 {input.genomefa}.fai > {output.ref_len}
    touch {output.spikein_len}

else
# THERE is SPIKEIN

    # create faidx for genome and spike fasta
    samtools faidx {input.genomefa}
    samtools faidx {input.spikein}

    # mask genome fa with genome blacklist
    bedtools maskfasta -fi {input.genomefa} -bed {input.blacklist} -fo ${{TMPDIR}}/masked_genome.fa

    # build bowtie index
    bowtie2-build --threads {threads} ${{TMPDIR}}/masked_genome.fa,{input.spikein} {params.bt2_base}

    # create len files
    cut -f1,2 {input.genomefa}.fai > {output.ref_len}
    cut -f1,2 {input.spikein}.fai > {output.spikein_len}

fi

# copy ref.json only after successfully finishing ref index building
if [[ -f {output.bt2} ]];then
    mv $(dirname {output.bt2})/tmp/ref.json {output.refjson}
fi

"""

        