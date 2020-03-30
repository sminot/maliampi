//
//  Reference package creation
//

container__vsearch = "golob/vsearch:2.7.1_bcw_0.2.0"
container__fastatools = "golob/fastatools:0.7.1__bcw.0.3.1"
container__pplacer = "golob/pplacer:1.1alpha19rc_BCW_0.3.1A"
container__seqinfosync = "golob/seqinfo_taxonomy_sync:0.2.1__bcw.0.3.0"
container__infernal = "golob/infernal:1.1.2_bcw_0.3.1"
container__raxml = "golob/raxml:8.2.11_bcw_0.3.0"

workflow make_refpkg_wf {
    take:
        sv_fasta_f

    main:
    //
    // Step 1. Load the repository
    // 
    repo_fasta = file(params.repo_fasta)
    repo_si = file(params.repo_si)


    //
    //  Step 2. Search the repo for candidates for the Sequence Variants (SV)
    //

    RefpkgSearchRepo(
        sv_fasta_f,
        repo_fasta
    )
    repo_recruits_f = RefpkgSearchRepo.out[0]
        
    //
    // Step 3. Filter SeqInfo to recruits
    //
    FilterSeqInfo(
        repo_recruits_f,
        repo_si
    )

    //
    // Step 4. (get) or build a taxonomy db
    //

    if ( (params.taxdmp == false) || file(params.taxdmp).isEmpty() ) {
        DlBuildTaxtasticDB()
        tax_db = DlBuildTaxtasticDB.out

    } else {
        BuildTaxtasticDB(
            file(params.taxdmp)
        )
        tax_db = BuildTaxtasticDB.out
    }

    // 
    // Step 5. Confirm seq info taxonomy matches taxdb
    //
    ConfirmSI(
        tax_db,
        FilterSeqInfo.out
    )

    //
    // Step 6. Align recruited seqs
    //
    AlignRepoRecruits(repo_recruits_f)

    //
    // Step 7. Convert alignment from STO -> FASTA format
    //
    ConvertAlnToFasta(
        AlignRepoRecruits.out[0]
    )

    //
    // Step 8. Make a tree from the alignment.
    //

    RaxmlTree(ConvertAlnToFasta.out)

    //
    // Step 9. Remove cruft from tree stats
    //
    RaxmlTree_cleanupInfo(RaxmlTree.out[1])

    //
    // Step 10. Make a tax table for the refpkg sequences
    //
    TaxtableForSI(
        tax_db,
        ConfirmSI.out
    )

    //
    // Step 11. Obtain the CM used for the alignment
    //
    ObtainCM()

    //
    // Step 12. Combine into a refpkg
    //
    CombineRefpkg(
        ConvertAlnToFasta.out,
        AlignRepoRecruits.out[0],
        RaxmlTree.out[0],
        RaxmlTree_cleanupInfo.out,
        TaxtableForSI.out,
        ConfirmSI.out,
        ObtainCM.out,
    )

    emit:
        refpkg_tgz = CombineRefpkg.out

}


process RefpkgSearchRepo {
    container "${container__vsearch}"
    label = 'multithread'

    input:
        file(sv_fasta_f)
        file(repo_fasta)
    
    output:
        file "${repo_fasta}.repo.recruits.fasta" 
        file "${repo_fasta}.uc" 
        file "${repo_fasta}.sv.nohit.fasta"
        file "${repo_fasta}.vsearch.log"
        

    """
    vsearch \
    --threads=${task.cpus} \
    --usearch_global ${sv_fasta_f} \
    --db ${repo_fasta} \
    --id=${params.repo_min_id} \
    --strand both \
    --uc=${repo_fasta}.uc --uc_allhits \
    --notmatched=${repo_fasta}.sv.nohit.fasta \
    --dbmatched=${repo_fasta}.repo.recruits.fasta \
    --maxaccepts=${params.repo_max_accepts} \
    | tee -a ${repo_fasta}.vsearch.log
    """
}



process FilterSeqInfo {
    container = "${container__fastatools}"
    label = 'io_limited'

    input:
        file (repo_recruits_f)
        file (repo_si)
    
    output:
        file('refpkg.seq_info.csv')

    """
    #!/usr/bin/env python
    import fastalite
    import csv

    with open('${repo_recruits_f}', 'rt') as fasta_in:
        seq_ids = {sr.id for sr in fastalite.fastalite(fasta_in)}
    with open('${repo_si}', 'rt') as si_in, open('refpkg.seq_info.csv', 'wt') as si_out:
        si_reader = csv.DictReader(si_in)
        si_writer = csv.DictWriter(si_out, si_reader.fieldnames)
        si_writer.writeheader()
        for r in si_reader:
            if r['seqname'] in seq_ids:
                si_writer.writerow(r)
    """
}

process DlBuildTaxtasticDB {
    container = "${container__pplacer}"
    label = 'io_limited'
    // errorStrategy = 'retry'

    output:
        file "taxonomy.db"

    afterScript "rm -rf dl/"


    """
    set -e

    mkdir -p dl/ && \
    taxit new_database taxonomy.db -u ftp://ftp.ncbi.nlm.nih.gov/pub/taxonomy/taxdmp.zip -p dl/
    """

}

process BuildTaxtasticDB {
    container = "${container__pplacer}"
    label = 'io_limited'
    // errorStrategy = 'retry'

    input:
        file taxdump_zip_f

    output:
        file "taxonomy.db"

    """
    taxit new_database taxonomy.db -z ${taxdump_zip_f}
    """
}

process ConfirmSI {
    container = "${container__seqinfosync}"
    label = 'io_limited'

    input:
        file taxonomy_db_f
        file refpkg_si_f
    
    output:
        file "${refpkg_si_f.baseName}.corr.csv"
    
    """
    seqinfo_taxonomy_sync.py \
    ${refpkg_si_f} ${refpkg_si_f.baseName}.corr.csv \
    --db ${taxonomy_db_f} --email ${params.email}
    """
}

process AlignRepoRecruits {
    container = "${container__infernal}"
    label = 'mem_veryhigh'

    input:
        file repo_recruits_f
    
    output:
        file "recruits.aln.sto"
        file "recruits.aln.scores" 
    
    """
    cmalign \
    --cpu ${task.cpus} --noprob --dnaout --mxsize ${params.cmalign_mxsize} \
    --sfile recruits.aln.scores -o recruits.aln.sto \
    /cmalign/data/SSU_rRNA_bacteria.cm ${repo_recruits_f}
    """
}

process ConvertAlnToFasta {
    container = "${container__fastatools}"
    label = 'io_limited'
    errorStrategy "retry"

    input: 
        file recruits_aln_sto_f
    
    output:
        file "recruits.aln.fasta"
    
    """
    #!/usr/bin/env python
    from Bio import AlignIO

    with open('recruits.aln.fasta', 'wt') as out_h:
        AlignIO.write(
            AlignIO.read(
                open('${recruits_aln_sto_f}', 'rt'),
                'stockholm'
            ),
            out_h,
            'fasta'
        )
    """
}

process RaxmlTree {
    container = "${container__raxml}"
    label = 'mem_veryhigh'
    errorStrategy = 'retry'

    input:
        file recruits_aln_fasta_f
    
    output:
        file "RAxML_bestTree.refpkg"
        file "RAxML_info.refpkg"
    
    """
    raxml \
    -n refpkg \
    -m ${params.raxml_model} \
    -s ${recruits_aln_fasta_f} \
    -p ${params.raxml_parsiomony_seed} \
    -T ${task.cpus}
    """
}

process RaxmlTree_cleanupInfo {
    container = "${container__raxml}"
    label = 'io_limited'
    errorStrategy = 'retry'

    input:
        file "RAxML_info.unclean.refpkg"
    
    output:
        file "RAxML_info.refpkg"


"""
#!/usr/bin/env python
with open("RAxML_info.refpkg",'wt') as out_h:
    with open("RAxML_info.unclean.refpkg", 'rt') as in_h:
        past_cruft = False
        for l in in_h:
            if "This is RAxML version" == l[0:21]:
                past_cruft = True
            if past_cruft:
                out_h.write(l)
"""
}


process TaxtableForSI {
    container = "${container__pplacer}"
    label = 'io_limited'
    // errorStrategy = 'retry'

    input:
        file taxonomy_db_f 
        file refpkg_si_corr_f
    output:
        file "refpkg.taxtable.csv"

    """
    taxit taxtable ${taxonomy_db_f} \
    --seq-info ${refpkg_si_corr_f} \
    --outfile refpkg.taxtable.csv
    """
}

process ObtainCM {
    container = "${container__infernal}"
    label = 'io_limited'

    output:
        file "refpkg.cm"
    
    """
    cp /cmalign/data/SSU_rRNA_bacteria.cm refpkg.cm
    """
}

process CombineRefpkg {
    container = "${container__pplacer}"
    label = 'io_limited'

    afterScript("rm -rf refpkg/*")
    publishDir "${params.output}/refpkg/", mode: 'copy'

    input:
        file recruits_aln_fasta_f
        file recruits_aln_sto_f
        file refpkg_tree_f 
        file refpkg_tree_stats_clean_f 
        file refpkg_tt_f
        file refpkg_si_corr_f
        file refpkg_cm
    
    output:
        file "refpkg.tgz"
    
    """
    taxit create --locus 16S \
    --package-name refpkg \
    --clobber \
    --aln-fasta ${recruits_aln_fasta_f} \
    --aln-sto ${recruits_aln_sto_f} \
    --tree-file ${refpkg_tree_f} \
    --tree-stats ${refpkg_tree_stats_clean_f} \
    --taxonomy ${refpkg_tt_f} \
    --seq-info ${refpkg_si_corr_f} \
    --profile ${refpkg_cm} && \
    ls -l refpkg/ && \
    tar czvf refpkg.tgz  -C refpkg/ .
    """
}