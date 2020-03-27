container__dada2 = "golob/dada2:1.12.0.ub.1804__bcw.0.3.1"
container__fastcombineseqtab = "golob/dada2-fast-combineseqtab:0.5.0__1.12.0__BCW_0.3.1"
container__dada2pplacer = "golob/dada2-pplacer:0.8.0__bcw_0.3.1A"

workflow dada2_wf {
    take: preprocessed_ch

    main:
    dada2_ft(preprocessed_ch)
    //
    // STEP 1: filter trim (by specimen)
    //

    ft_reads = dada2_ft.out.branch{
        empty: file(it[2]).isEmpty() || file(it[3]).isEmpty()
        valid: true
    }

    //
    // STEP 2: dereplicate (by specimen)
    //
    dada2_derep(ft_reads.valid)

    //
    // STEP 3: learn error by batch
    //
    ft_reads.valid
        .toSortedList({a, b -> a[0] <=> b[0]})
        .flatMap()
        .groupTuple(by: 1)
        .multiMap {
            it -> forR1: forR2: it
        }.set { ft_batches }

    ft_batches.forR1
        .map {
            [it[0], it[1], it[2], 'R1']
        }
        .mix(ft_batches.forR2
            .map{
                [it[0], it[1], it[3], 'R2']
            }
        )
        .set{
            derep_by_batch
        }
    dada2_learn_error(derep_by_batch)

    //
    // STEP 4: Group up derep and errM objects by batch
    //
    dada2_derep.out
        .multiMap {
            it -> forR1: forR2: it
        }.set { derep_batches }

        derep_batches.forR1.map{
            [
                it[1],  //batch
                'R1',   // R1 or R2
                it[0],  // specimen
                it[2],   // derep file
            ]
        }.mix(derep_batches.forR2.map{
            [
                it[1],  //batch
                'R2',   // R1 or R2
                it[0],  // specimen
                it[3],   // derep file
            ]
        })
        .toSortedList({a, b -> a[2] <=> b[2]})
        .flatMap()
        .groupTuple(by: [0, 1])
        .combine(dada2_learn_error.out, by: [0,1])
        .map{ r-> [
            r[0], // batch
            r[1], // read_num
            r[2],  // specimen names (list)
            r[3],  // derep files (list)
            r[4],  // errM file
            r[3].collect { f -> return file(f).getSimpleName()+".dada.rds" }
        ]}
        .set { batch_err_dereps_ch }
        
    dada2_derep_batches(batch_err_dereps_ch)

    //
    // STEP 5: Apply the error model by batch, using pseudo-pooling to improve yield.
    //
    dada2_dada(dada2_derep_batches.out)
    // split the dada2 results out
    dada2_demultiplex_dada(dada2_dada.out)
    // Flatten things back out to one-specimen-per-row
    dada2_demultiplex_dada.out
        .flatMap{
            br -> 
            fl = [];
            br[2].eachWithIndex{ 
                it, i ->  fl.add([
                    br[2][i], // specimen
                    br[1], // readnum
                    br[3][i], // dada file
                    br[0] // batch
                ])
            }
            return fl;
        }
        .toSortedList({a, b -> a[0] <=> b[0]})
        .flatMap()
        .groupTuple(by: [0])
        .map { spr ->
            r1_idx = spr[1].indexOf('R1')
            r2_idx = spr[1].indexOf('R2')
            [
                spr[0],  // specimen
                spr[3][0], // batch
                file(spr[2][r1_idx]), // dada_1
                file(spr[2][r2_idx]), // dada_2
            ]}
        .join(dada2_derep.out)
        .map {
            [
                it[0],       // specimen
                it[1],      // batch
                file(it[2]),  // dada_R1
                file(it[3]), // dada_R2
                file(it[5]),  // derep_R1
                file(it[6])   // derep_R2
            ]
        }
        .set { dada2_dada_sp_ch }

    //
    // STEP 6: Merge reads, using the dereplicated seqs and applied model
    //
    dada2_merge(dada2_dada_sp_ch)
    // Filter out empty merged files.
    dada2_merge.out.branch{
        empty: file(it[2]).isEmpty()
        valid: true
    }.set { dada2_merge_filtered }

    //
    // STEP 7. Make a seqtab for each specimen
    //
    dada2_seqtab_sp( dada2_merge_filtered.valid )

    //
    // STEP 8. Combine seqtabs
    //
    // Do this by batch to help with massive data sets
    dada2_seqtab_combine_batch(    
        dada2_seqtab_sp.out
            .groupTuple(by: 0)
            .map{[
                it[0],
                it[2]
            ]}
    )
    // then combine each batch seqtab into one seqtab to rule them all
    dada2_seqtab_combine_all(
        dada2_seqtab_combine_batch.out
            .map{ file(it) }
            .toSortedList()
    )
    
    //
    // STEP 8. Remove chimera on combined seqtab
    //
    dada2_remove_bimera(
        dada2_seqtab_combine_all.out.map{ file(it) }
    )

    // STEP 9. Transform output to be pplacer and mothur style
    dada2_convert_output(
        dada2_remove_bimera.out[0].map{ file(it) }
    )

    // STEP 10. Collect all the failures
    ft_reads.empty.map{ [it[0], 'Empty after FT']}.mix(
    dada2_merge_filtered.empty.map{ [it[1], 'Empty after merge']})
    .set{ failures }

    emit:
       sv_fasta         = dada2_convert_output.out[0] 
       sv_map           = dada2_convert_output.out[1]
       sv_weights       = dada2_convert_output.out[2]
       sv_long          = dada2_convert_output.out[3]
       sv_sharetable    = dada2_convert_output.out[4]
       sv_table         = dada2_remove_bimera.out[0]
       failures         = failures
}


process dada2_ft {
    container "${container__dada2}"
    label 'io_limited'
    errorStrategy "ignore"

    input:
        tuple val(specimen), val(batch), file(R1), file(R2)
    
    output:
        tuple val(specimen), val(batch), file("${R1.getSimpleName()}.dada2.ft.fq.gz"), file("${R2.getSimpleName()}.dada2.ft.fq.gz")
    """
    #!/usr/bin/env Rscript
    library('dada2'); 
    filterAndTrim(
        '${R1}', '${R1.getSimpleName()}.dada2.ft.fq.gz',
        '${R2}', '${R2.getSimpleName()}.dada2.ft.fq.gz',
        trimLeft = ${params.trimLeft},
        maxN = ${params.maxN},
        maxEE = ${params.maxEE},
        truncLen = c(${params.truncLenF}, ${params.truncLenR}),
        truncQ = ${params.truncQ},
        compress = TRUE,
        verbose = TRUE,
        multithread = ${task.cpus}
    )
    """
}

process dada2_derep {
    container "${container__dada2}"
    label 'io_limited'
    errorStrategy "ignore"

    input:
        tuple val(specimen), val(batch), file(R1), file(R2)
    
    output:
        tuple val(specimen), val(batch), file("${R1.getSimpleName()}.dada2.ft.derep.rds"), file("${R2.getSimpleName()}.dada2.ft.derep.rds")
    
    """
    #!/usr/bin/env Rscript
    library('dada2');
    derep_1 <- derepFastq('${R1}');
    saveRDS(derep_1, '${R1.getSimpleName()}.dada2.ft.derep.rds');
    derep_2 <- derepFastq('${R2}');
    saveRDS(derep_2, '${R2.getSimpleName()}.dada2.ft.derep.rds');
    """ 
}

process dada2_learn_error {
    container "${container__dada2}"
    label 'multithread'
    errorStrategy "retry"
    maxRetries 10
    publishDir "${params.output}/sv/errM/${batch}", mode: 'copy'

    input:
        tuple val(batch_specimens), val(batch), file(reads), val(read_num)

    output:
        tuple batch, read_num, file("${batch}.${read_num}.errM.rds"), file("${batch}.${read_num}.errM.csv")

    """
    #!/usr/bin/env Rscript
    library('dada2');
    err <- learnErrors(
        unlist(strsplit(
            '${reads}',
            ' ',
            fixed=TRUE
        )),
        multithread=${task.cpus},
        MAX_CONSIST=${params.errM_maxConsist},
        randomize=${params.errM_randomize},
        nbases=${params.errM_nbases},
        verbose=TRUE
    );
    saveRDS(err, "${batch}.${read_num}.errM.rds"); 
    write.csv(err, "${batch}.${read_num}.errM.csv");
    """
}

process dada2_derep_batches {
    container "${container__dada2}"
    label 'io_limited'
    errorStrategy "retry"
    maxRetries 10

    input:
        tuple val(batch), val(read_num), val(specimens), file(dereps), val(errM), val(dada_fns)
    
    output:
        tuple val(batch), val(read_num), val(specimens), file("${batch}_${read_num}_derep.rds"), val(errM), val(dada_fns)
    
    """
    #!/usr/bin/env Rscript
    library('dada2');
    derep <- lapply(
        unlist(strsplit('${dereps}', ' ', fixed=TRUE)),
        readRDS
    );
    saveRDS(derep, "${batch}_${read_num}_derep.rds")
    """
}

process dada2_dada {
    container "${container__dada2}"
    label 'multithread'
    errorStrategy "retry"
    maxRetries 10

    input:
        tuple val(batch), val(read_num), val(specimens), file(derep), file(errM), val(dada_fns)

    output:
        tuple val(batch), val(read_num), val(specimens), file("${batch}_${read_num}_dada.rds"), val(dada_fns)
    """
    #!/usr/bin/env Rscript
    library('dada2');
    errM <- readRDS('${errM}');
    derep <- readRDS('${derep}');
    dadaResult <- dada(derep, err=errM, multithread=${task.cpus}, verbose=TRUE, pool="pseudo");
    saveRDS(dadaResult, "${batch}_${read_num}_dada.rds");
    """
}


process dada2_demultiplex_dada {
    container "${container__dada2}"
    label 'io_limited'
    errorStrategy "retry"
    maxRetries 10

    input:
        tuple val(batch), val(read_num), val(specimens), file(dada), val(dada_fns)
    
    output:
        tuple val(batch), val(read_num), val(specimens), file(dada_fns)

    """
    #!/usr/bin/env Rscript
    library('dada2');
    dadaResult <- readRDS('${dada}');
    dada_names <- unlist(strsplit(
        gsub('(\\\\[|\\\\])', "", "${dada_fns}"),
        ", "));
    print(dada_names);
    sapply(1:length(dadaResult), function(i) {
        saveRDS(dadaResult[i], dada_names[i]);
    });
    """
}

process dada2_merge {
    container "${container__dada2}"
    label 'multithread'
    errorStrategy "ignore"

    input:
        tuple val(specimen), val(batch), file(R1dada), file(R2dada), file(R1), file(R2)

    output:
        tuple val(batch), val(specimen), file("${specimen}.dada2.merged.rds")
    
    """
    #!/usr/bin/env Rscript
    library('dada2');
    dada_1 <- readRDS('${R1dada}');
    derep_1 <- readRDS('${R1}');
    dada_2 <- readRDS('${R2dada}');
    derep_2 <- readRDS('${R2}');        
    merger <- mergePairs(
        dada_1, derep_1,
        dada_2, derep_2,
        verbose=TRUE,
    );
    saveRDS(merger, "${specimen}.dada2.merged.rds");
    """
}

process dada2_seqtab_sp {
    container "${container__dada2}"
    label 'io_limited'
    errorStrategy "retry"
    maxRetries 10

    input:
        tuple val(batch), val(specimen), file(merged)

    output:
        tuple val(batch), val(specimen), file("${specimen}.dada2.seqtab.rds")

    """
    #!/usr/bin/env Rscript
    library('dada2');
    merged <- readRDS('${merged}');
    seqtab <- makeSequenceTable(merged);
    rownames(seqtab) <- c('${specimen}');
    saveRDS(seqtab, '${specimen}.dada2.seqtab.rds');
    """
}

process dada2_seqtab_combine_batch {
    container "${container__fastcombineseqtab}"
    label 'io_mem'
    //errorStrategy "retry"
    maxRetries 10

    input:
        tuple val(batch), file(sp_seqtabs_rds)

    output:
        file("${batch}.dada2.seqtabs.rds")

    """
    set -e

    combine_seqtab \
    --rds ${batch}.dada2.seqtabs.rds \
    --seqtabs ${sp_seqtabs_rds}
    """
}

process dada2_seqtab_combine_all {
    container "${container__fastcombineseqtab}"
    label 'io_mem'
    //errorStrategy "retry"
    maxRetries 10

    input:
        file(seqtabs_rds)

    output:
        file("combined.dada2.seqtabs.rds")

    """
    set -e

    combine_seqtab \
    --rds combined.dada2.seqtabs.rds \
    --seqtabs ${seqtabs_rds}
    """
}


process dada2_remove_bimera {
    container "${container__dada2}"
    label 'mem_veryhigh'
    errorStrategy "retry"
    maxRetries 10
    publishDir "${params.output}/sv/", mode: 'copy'

    input:
        file(combined_seqtab)

    output:
        file("dada2.combined.seqtabs.nochimera.csv")
        file("dada2.combined.seqtabs.nochimera.rds")

    script:
    """
    #!/usr/bin/env Rscript
    library('dada2');
    seqtab <- readRDS('${combined_seqtab}');
    seqtab_nochim <- removeBimeraDenovo(
        seqtab,
        method = '${params.chimera_method}',
        multithread = ${task.cpus}
    );
    saveRDS(seqtab_nochim, 'dada2.combined.seqtabs.nochimera.rds'); 
    write.csv(seqtab_nochim, 'dada2.combined.seqtabs.nochimera.csv', na='');
    print((sum(seqtab) - sum(seqtab_nochim)) / sum(seqtab));
    """
}


process dada2_convert_output {
    container "${container__dada2pplacer}"
    label 'io_mem'
    publishDir "${params.output}/sv/", mode: 'copy'
    errorStrategy "retry"

    input:
        file(final_seqtab_csv)

    output:
        file "dada2.sv.fasta"
        file "dada2.sv.map.csv"
        file "dada2.sv.weights.csv"
        file "dada2.specimen.sv.long.csv"
        file "dada2.sv.shared.txt"

    """
    dada2-seqtab-to-pplacer \
    -s ${final_seqtab_csv} \
    -f dada2.sv.fasta \
    -m dada2.sv.map.csv \
    -w dada2.sv.weights.csv \
    -L dada2.specimen.sv.long.csv \
    -t dada2.sv.shared.txt
    """
}