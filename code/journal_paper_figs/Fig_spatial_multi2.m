% this script is a wrapper that loads some data (or simulates it) and then
% calls the most recent FOOPSI function to infer spike trains and
% parameters

clear, clc

%% simulate data
fname = 'wrapper_data';
% generate spatial filters
Nc      = 2;                                % # of cells in the ROI
neur_w  = 10;                               % height per neuron
height  = 15;                               % height of frame (pixels)
width   = Nc*neur_w;                        % width of frame (pixels)
Npixs   = height*width;                     % # pixels in ROI
x       = linspace(-5,5,width);
y       = linspace(-5,5,height);
[X,Y]   = meshgrid(x,y);
g1      = zeros(Npixs,Nc);
g2      = 0*g1;
Sigma1  = diag([1,1])*3;                    % var of positive gaussian
Sigma2  = diag([1,1])*5;                    % var of negative gaussian
mu      = [1 1]'*linspace(-2,2,Nc);         % means of gaussians for each cell (distributed across pixel space)
w       = Nc:-1:1;                          % weights of each filter
for i=1:Nc
    g1(:,i)  = w(i)*mvnpdf([X(:) Y(:)],mu(:,i)',Sigma1);
    g2(:,i)  = w(i)*mvnpdf([X(:) Y(:)],mu(:,i)',Sigma2);
end

% set simulation metadata
Meta.T       = 600;                         % # of time steps
Meta.dt      = 0.005;                       % time step size
Meta.Np      = Npixs;                       % # of pixels in each image
Meta.h       = height;                       % height of frame (pixels)
Meta.w       = width;                      % width of frame (pixels)

% initialize params
for i=1:Nc
    P.a(:,i)=g1(:,i)-g2(:,i);
end
P.b     = 0.1*sum(P.a,2);                   % baseline is a scaled down version of the sum of the spatial filters

P.sig   = 0.01;                             % stan dev of noise (indep for each pixel)
C_0     = 0;                                % initial calcium
tau     = round(100*rand(Nc,1))/100+0.05;   % decay time constant for each cell
P.gam   = 1-Meta.dt./tau(1:Nc);             % set gam
P.lam   = round(10*rand(Nc,1))+5;           % rate-ish, ie, lam*dt=# spikes per second

% simulate data
n=zeros(Meta.T,Nc);                         % pre-allocate memory for spike train
C=n;                                        % pre-allocate memory for calcium
for i=1:Nc
    n(1,i)      = C_0;
    n(2:end,i)  = poissrnd(P.lam(i)*Meta.dt*ones(Meta.T-1,1));  % simulate spike train
    n(n>1)      = 1;                                            % make only 1 spike per bin
    C(:,i)      = filter(1,[1 -P.gam(i)],n(:,i));               % calcium concentration
end
Z = 0*n(:,1);
F = C*P.a' + (1+Z)*P.b'+P.sig*randn(Meta.T,Npixs);              % fluorescence

% set user defined parameters
User.MaxIter = 25;                          % # iterations of EM to estimate params
User.Nc      = Nc;                          % # cells per ROI
User.Plot    = 1;                           % whether to plot filter with each iteration
User.Thresh  = 1;                           % whether to threshold spike train before estimating params (we always keep this on)

save([fname '.mat'],'F','P','Meta','User')

%% infer spike trains and parameters

% init params for alg
PP=P;
[U,S,V]=pca_approx(F,User.Nc);
for j=1:User.Nc, PP.a(:,j)=V(:,j); end
% PP.b    = 0*PP.a;
% PP.lam  = 10;
PP.sig  = 0.5*P.sig;
[I.n I.P] = FOOPSI_v3_02_02(F,PP,Meta,User);

%% plot results
figure(4), clf,

Pl.g    = [0.75 0.75 0.75];     % gray color
Pl.fs   = 12;                   % font size
Pl.w1   = 0.28;                 % width of subplot  
Pl.wh   = [Pl.w1 Pl.w1];        % width and height of subplots
Pl.b1   = 0.67;                 % bottom of topmost subplt
Pl.l1   = 0.41;                 % left side of left subplot on right half
Pl.l2   = Pl.l1+0.3;            % left side of right subplot on right half
Pl.s1   = Pl.w1+0.043;          % space between subplots on right side
Pl.s2   = Pl.w1+0.043;          % space between subplots on left side
Pl.ms   = 5;                    % marker size

% plot mean image frame
subplot('Position',[0.05 Pl.b1-2*Pl.s1 Pl.w1 Pl.w1*.75]) %[left bottom width height]
imagesc(reshape(mean(F),Meta.h,Meta.w))
set(gca,'XTickLabel',[],'YTickLabel',[])
ylabel('Mean Frame','FontSize',Pl.fs)

% align inferred cell with actual one
j_inf=0*n(1:User.Nc);
for j=1:User.Nc
    cc=0*n(1:User.Nc);
    for k=1:User.Nc
        cc_temp=corrcoef(n(:,j),I.n(:,k)); cc(k)=cc_temp(2);
    end
    [foo j_inf(j)]=max(cc);
end

% plot spatial filters
for j=1:Nc,
    ht(j)=subplot('Position',[Pl.l1 Pl.b1-(j-1)*Pl.s1 Pl.wh]); %nrows,ncols,ncols*(j-1)+1),
    imagesc(reshape((P.a(:,j)),Meta.h,Meta.w)),
    set(gca,'XTickLabel',[],'YTickLabel',[])
    ylab=ylabel([{'Spatial Filter'}],'FontSize',Pl.fs);

    hf(j)=subplot('Position',[Pl.l2 Pl.b1-(j-1)*Pl.s1 Pl.wh]); %nrows,ncols,ncols*(j-1)+1),
    imagesc(reshape((I.P.a(:,j_inf(j))),Meta.h,Meta.w)),
    set(gca,'XTickLabel',[],'YTickLabel',[])
    if j==1, title('Estimated','FontSize',Pl.fs), end
end
title(ht(1),'Truth','FontSize',Pl.fs),
title(hf(1),'Estimated','FontSize',Pl.fs),

%  plot background
subplot('Position',[Pl.l1 Pl.b1-2*Pl.s1 Pl.wh]); %nrows,ncols,ncols*(j-1)+1),
imagesc(reshape(P.b,Meta.h,Meta.w)),
ylab=ylabel(['Background'],'FontSize',Pl.fs);
set(gca,'XTickLabel',[],'YTickLabel',[])

subplot('Position',[Pl.l2 Pl.b1-2*Pl.s1 Pl.wh]); %nrows,ncols,ncols*(j-1)+1),
imagesc(reshape(I.P.b,Meta.h,Meta.w)),
set(gca,'XTickLabel',[],'YTickLabel',[])

% plot inferred spike trains
nnan=n; nnan(nnan==0)=NaN;
dt_vec=Meta.dt:Meta.dt:Meta.T*Meta.dt;
NTicks=3;
XTicks=linspace(Meta.T/NTicks,Meta.T,NTicks);
for j=1:User.Nc
    hc(j)=subplot('Position',[0.05 Pl.b1-(j-1)*Pl.s2 Pl.w1 Pl.w1*.9]); %[left bottom width height]
    hold on
    stem(nnan(:,j),'LineStyle','none','Marker','v','MarkerEdgeColor',Pl.g,'MarkerFaceColor',Pl.g)
    bar(I.n(:,j_inf(j))/max(I.n(:,j_inf(j))))
    axis('tight')
    set(gca,'YTick',[0 1],'YTickLabel',[])
    ylab=ylabel(hc(j),['Neuron ' num2str(j)],'FontSize',Pl.fs);
    if j==1,
        set(gca,'XTick',XTicks,'XTickLabel',[])
        title([{'Spike Trains'}],'FontSize',Pl.fs)
    else
        set(gca,'XTick',XTicks,'XTickLabel',XTicks*Meta.dt)
        xlabel('Time (sec)','FontSize',Pl.fs,'Position',[299 -0.14 1])
    end
end

% print fig
wh=[6 6];   %width and height
DirName = '../../docs/journal_paper/figs/';
FileName = 'multi_spatial';
PrintFig(wh,DirName,FileName);
