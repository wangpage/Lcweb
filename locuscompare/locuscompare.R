# Make locuscatter plots
# Boxiang Liu
# 2017-12-07
# library(R.utils)
library(data.table)
library(cowplot)
# library(ggrepel)
library(stringr)
source('config/config.R')

read_metal=function(in_fn,marker_col='rsid',pval_col='pval'){
	if (is.character(in_fn)){
		if (grepl('.gz',in_fn)){
			d=fread(sprintf('gunzip -c %s',in_fn))
		} else {
			d=fread(in_fn)
		}
		
		setnames(d,c(marker_col,pval_col),c('rsid','pval'))
		d=d[,list(rsid,pval,logp=-log10(pval))]
	} else if (is.data.frame(in_fn)){
		d=in_fn
	} else {
		stop('in_fn must be a string or a data.frame')
	}
	return(d)
}

get_chr=function(eqtl_fn){
	as.integer(str_replace(unique(fread(eqtl_fn)$chr),'chr',''))
}

get_position=function(x,genome){
    stopifnot('rsid' %in% colnames(x))
    res = dbGetQuery(
		conn = locuscompare_pool,
		statement = sprintf(
			"select rsid, chr, pos 
			from %s 
			where rsid in ('%s')",
			genome,
			paste0(x$rsid,collapse="','")
        )
    )
    y=merge(x,res,by='rsid')
    return(y)
}

retrieve_LD = function(chr,snp,population){
    res1 = dbGetQuery(
        conn = locuscompare_pool,
        statement = sprintf(
            "select SNP_A, SNP_B, R2
			from tkg_p3v5a_ld_chr%s_%s
			where SNP_A = '%s';",
            chr,
            population,
            snp
        )
    )
    
    res2 = dbGetQuery(
        conn = locuscompare_pool,
        statement = sprintf(
            "select SNP_B as SNP_A, SNP_A as SNP_B, R2
			from tkg_p3v5a_ld_chr%s_%s
			where SNP_B = '%s';",
            chr,
            population,
            snp
        )
    )
    
    res = rbind(res1,res2)
    setDT(res)
    return(res)
}

retrieve_vcf=function(merged,tmp_dir){
	chr=unique(merged$chr)
	print(merged)
	chr=gsub('chr','',chr)
	if (length(chr)!=1) {
		stop('SNPs must be on a single chromosome!')
	}
	pos_max=max(merged$pos)
	pos_min=min(merged$pos)
	vcf_fn=sprintf('%s/1000genomes_chr%s_%s_%s.vcf.gz',tmp_dir,chr,pos_min,pos_max)
	if (chr %in% as.character(1:22)){
	  command=sprintf('%s -h %s/ALL.chr%s.phase3_shapeit2_mvncall_integrated_v5a.20130502.genotypes.vcf.gz %s:%s-%s | %s > %s',tabix,tkg_dir,chr,chr,pos_min,pos_max,bgzip,vcf_fn)
	} else if (chr == 'X'){
	  command=sprintf('%s -h %s/ALL.chrX.phase3_shapeit2_mvncall_integrated_v1b.20130502.genotypes.vcf.gz %s:%s-%s | %s > %s',tabix,tkg_dir,chr,pos_min,pos_max,bgzip,vcf_fn)
	} else if (chr == 'Y'){
	  command=sprintf('%s -h %s/ALL.chrY.phase3_integrated_v2a.20130502.genotypes.vcf.gz %s:%s-%s | %s > %s',tabix,tkg_dir,chr,pos_min,pos_max,bgzip,vcf_fn)
	} else {
	  stop('Chromosome must be 1-22, X or Y')
	}
	print(command)
	system(command)
	
	if (file.exists(sprintf('ALL.chr%s.phase3_shapeit2_mvncall_integrated_v5a.20130502.genotypes.vcf.gz.tbi',chr))){
	  unlink(sprintf('ALL.chr%s.phase3_shapeit2_mvncall_integrated_v5a.20130502.genotypes.vcf.gz.tbi',chr)) # remove index file downloaded by tabix
	}
	return(vcf_fn)
}


extract_population=function(population,out_file,panel){
	panel=fread(panel)
	x=panel[super_pop==population,list(sample,sample)]
	fwrite(x,out_file,sep='\t',col.names=FALSE)
}


subset_vcf=function(vcf_in,rsid,population,vcf_out,out_dir,pop_fn){
	rsid_fn=sprintf('%s/rsid.txt',out_dir)
	rsid_fn=tempfile(pattern = "rsid-", tmpdir = out_dir, fileext = ".txt")
	on.exit(unlink(rsid_fn))
	
	write.table(rsid,rsid_fn,sep='\t',col.names=FALSE,row.names=FALSE,quote=FALSE)
	
	command=sprintf('%s --vcf %s --keep-allele-order --keep %s --extract %s --recode vcf-iid --out %s',plink,vcf_in,pop_fn,rsid_fn,vcf_out)
	print(command)
	system(command)
}

calc_LD=function(rsid,chr,pop,out_dir,vcf_fn,panel=NULL){
	pop_fn=sprintf('%s/population/%s.txt',data_dir,pop)
	rsid_fn=sprintf('%s/rsid.txt',out_dir)

	subset_vcf_prefix=sprintf('%s/%s',out_dir,pop)
	subset_vcf_fn=sprintf('%s/%s.vcf',out_dir,pop)
	subset_vcf(vcf_fn,rsid,pop,subset_vcf_prefix,out_dir,pop_fn)
	
	command=sprintf('%s --vcf %s --keep-allele-order --r2 --ld-window 9999999 --ld-window-kb 9999999 --out %s/%s',plink,subset_vcf_fn,out_dir,pop)
	print(command)
	system(command)
	
	ld=fread(sprintf('%s/%s.ld',out_dir,pop))
	ld2=ld[,list(CHR_A=CHR_B,BP_A=BP_B,SNP_A=SNP_B,CHR_B=CHR_A,BP_B=BP_A,SNP_B=SNP_A,R2)]
	ld=rbind(ld,ld2)
	return(ld)
}


assign_color=function(rsid,snp,ld){
    if (is.null(ld)){
        color=rep('blue4',times=length(rsid))
        names(color)=rsid
        return(color)
    }
    # TODO: when snp is not in ld$SNP_A, the color of the 
    # SNP in the locuszoom plot is white. Add a if condition
    # that triggers when snp is not in ld$SNP_A, and add snp
    # into ld$SNP_A. 
	color_dt=ld %>% 
		dplyr::filter(SNP_A==snp) %>% 
		dplyr::transmute(
			rsid=SNP_B,
			color=as.character(cut(
				R2,
				breaks=c(0,0.2,0.4,0.6,0.8,1),
				labels=c('blue4','skyblue','darkgreen','orange','red'),
				include.lowest=TRUE)))
	snps_not_in_ld = rsid[!(rsid %in% ld$SNP_B)]
	if (length(snps_not_in_ld)>0) {
	    color_dt=rbind(color_dt,data.frame(rsid=snps_not_in_ld,color='blue4'))
	}
	if (snp %in% color_dt$rsid){
	    color_dt[color_dt$rsid==snp,]$color='purple'    
	}
	color=as.character(color_dt$color)
	names(color)=color_dt$rsid
	return(color)
}


assign_shape=function(merged,snp){
	shape=ifelse(merged$rsid==snp,23,21)
	names(shape)=merged$rsid
	return(shape)
}


assign_size=function(merged,snp){
	size=ifelse(merged$rsid==snp,3,2)
	names(size)=merged$rsid
	return(size)
}

make_combined_plot=function(merged,title1,title2,ld,snp=NULL){
  if (is.null(snp)){
    snp=merged[which.min(pval1+pval2),rsid]
  } else {
    if(!snp%in%merged$rsid){
      stop(sprintf('%s not found in %s',snp,in_fn1))
    }
  }
  print(sprintf('INFO - %s',snp))
  
  color=assign_color(merged$rsid,snp,ld)
  shape=assign_shape(merged)
  size=assign_size(merged)
  merged[,label:=ifelse(rsid==snp,rsid,'')]
  
  theme_set(theme_light(base_size=14))
  p1=make_locuscatter(merged,title1,title2,ld,color,shape,size)
  p2=make_locuszoom(merged[,list(rsid,logp=logp1,label)],title1,ld,color,shape,size)
  p2=p2+theme(axis.text.x=element_blank(),axis.title.x=element_blank())
  p3=make_locuszoom(merged[,list(rsid,logp=logp2,label)],title2,ld,color,shape,size)
  p4=plot_grid(p2,p3,align='v',nrow=2)
  p5=plot_grid(p1,p4)
  return(p5)
}




make_locuscatter=function(merged,title1,title2,ld,color,shape,size,legend=TRUE){
	p = ggplot(merged,aes(logp1,logp2))+
		geom_point(aes(fill=rsid,size=rsid,shape=rsid),alpha=0.8)+
		xlab(paste(title1,' -log10(P)'))+ylab(paste(title2,' -log10(P)'))+
		scale_fill_manual(values=color,guide='none')+
		scale_shape_manual(values=shape,guide='none')+
		scale_size_manual(values=size,guide='none')+
		geom_text(aes(label=label),hjust = 1.1)+
	  theme(panel.background = element_rect(fill = "white"),axis.line = element_line(color = "black", size = 0.5), 
	        axis.line.x = element_line(color = "black", size = 0.5),
	        axis.line.y = element_line(color = "black", size = 0.5))
	if (legend){
		legend_box=data.frame(x=0.8,y=seq(0.4,0.2,-0.05))
		p1=ggdraw(p)+geom_rect(data=legend_box,aes(xmin=x,xmax=x+0.05,ymin=y,ymax=y+0.05),color='black',fill=rev(c('blue4','skyblue','darkgreen','orange','red')))+
			draw_label('0.8',x=legend_box$x[1]+0.05,y=legend_box$y[1],hjust=-0.3,size=10)+
			draw_label('0.6',x=legend_box$x[2]+0.05,y=legend_box$y[2],hjust=-0.3,size=10)+
			draw_label('0.4',x=legend_box$x[3]+0.05,y=legend_box$y[3],hjust=-0.3,size=10)+
			draw_label('0.2',x=legend_box$x[4]+0.05,y=legend_box$y[4],hjust=-0.3,size=10)+
			draw_label(parse(text='r^2'),x=legend_box$x[1]+0.05,y=legend_box$y[1],vjust=-2.0,size=10)
	} else {
		p1=p
	}

	return(p1)
}

make_locuszoom=function(metal,title,ld,color,shape,size,y_string='logp'){
	data=metal
	chr=unique(data$chr)
	p = ggplot(data,aes_string(x='pos',y=y_string))+
		geom_point(aes(fill=rsid,size=rsid,shape=rsid),alpha=0.8)+
		scale_fill_manual(values=color,guide='none')+
		scale_shape_manual(values=shape,guide='none')+
		scale_size_manual(values=size,guide='none')+
		scale_x_continuous(labels=function(x){sprintf('%.2f',x/1e6)},expand=c(0.01,0))+
		geom_text(aes(label=label),hjust = 1.1)+
		xlab(paste0('chr',chr,' (Mb)'))+
		ylab(paste(title,'\n-log10(P)'))+
		theme(panel.background = element_rect(fill = "white"),plot.margin=unit(c(0.5, 1, 0.5, 0.5), "lines"), axis.line = element_line(color = "black", size = 0.5),
		      axis.line.x = element_line(color = "black", size = 0.5), axis.line.y = element_line(color = "black", size = 0.5))
	return(p)
}

main=function(in_fn1,marker_col1='rsid',pval_col1='pval',title1='eQTL',
			  in_fn2,marker_col2='rsid',pval_col2='pval',title2='GWAS',
			  snp=NULL,fig_fn='1.pdf',chr=get_chr(in_fn1)){
	
	d1=read_metal(in_fn1,marker_col1,pval_col1)
	d2=read_metal(in_fn2,marker_col2,pval_col2)
	
	# chr=get_chr(in_fn1)
	merged=merge(d1,d2,by='rsid',suffixes=c('1','2'),all=FALSE)
	ld=calc_LD(merged$rsid,chr,'EUR',out_dir)
	
	p=make_combined_plot(merged,title1,title2,ld,snp)
	save_plot(fig_fn,p,base_height=4,base_width=8)
}
