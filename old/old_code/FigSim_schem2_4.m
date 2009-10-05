% this script compares Wiener and Fast Filters
%
% 1) set simulation metadata (eg, dt, T, # particles, etc.)
% 2) initialize parameters
% 3) generate fake data
% 4) infers spikes using a variety of approaches
% 5) plots results
%
% 2_0: we estimate b in F_t = a C_t + b + sigma*epsilon_t
% 2_1: totally reparameterized. see section 3
% 2_2: allow for initial condition on C
% 2_3: don't know, something else buggy i think
% 2_4: reparameterized a bit.

clear, clc, fprintf('\nNoisy Simulation Fig\n')

% 1) set simulation metadata
Sim.T       = 500;                              % # of time steps
Sim.dt      = 0.005;                            % time step size
Sim.Plot    = 1;                                % whether to plot
% Sim.MaxIter = 0;                                % max number of iterations

% 2) initialize parameters
P.a     = 10;
P.b     = 0;
P.sig   = 3;                                    % stan dev of noise
C_0     = 0;
tau     = 0.05;                                 % decay time constant
P.gam   = 1-Sim.dt/tau;
P.lam   = 10;                                   % rate-ish, ie, lam*dt=# spikes per second

% 3) simulate data
n = poissrnd(P.lam*Sim.dt*ones(Sim.T-1,1));     % simulate spike train
n = [C_0; n];                                   % set initial calcium
C = filter(1,[1 -P.gam],n);                     % calcium concentration
F = P.a*C+P.b+P.sig*randn(Sim.T,1);             % fluorescence

% 4) estimate params from real spikes and plot F,C,n
Phat = FastParams3_1(F,C,n,Sim.T,Sim.dt);
orderfields(P), orderfields(Phat), figure(10), clf,
plot(Phat.a*filter(1,[1 -Phat.gam],n)+ Phat.b,'linewidth',2),
hold on, plot(F,'k'), bar(-n), axis([1000 1500 -1 5])
Sim.dt/(1-Phat.gam), tau
%% 5) infer spikes and estimate parameters

% initialize parameters
P2 = P;
P2.lam  = 2*P.lam;
P2.sig  = 2*P.sig;
P2.a= 10*P.a;

for q=1:2;
    tic
    if q==1
        I{q}.name       = [{'Fast'}; {'Filter'}];
        [I{q}.n I{q}.P] = FOOPSI2_51(F,P,Sim);
    elseif q==2
        P2.lam  = 2*P.lam;
        P2.sig  = 2*P.sig;
        Sim.MaxIter=10;
        I{q}.name       = [{'Fast'}; {'Filter'}];
        [I{q}.n I{q}.P] = FOOPSI2_51(F,P,Sim);
    end
    toc
end

%% 6) plot results

orderfields(P), orderfields(Phat), orderfields(I{q}.P)

fig=figure(1); clf,
nrows = 3+q;                                    % set number of rows
Pl.xlims=[100 Sim.T];                           % time steps to plot
Pl.nticks=5;                                    % number of ticks along x-axis
Pl.n=double(n); Pl.n(Pl.n==0)=NaN;              % store spike train for plotting
Pl = PlotParams(Pl);                            % generate a number of other parameters for plotting

% plot fluorescence data
i=1; h(1) = subplot(nrows,1,i);
Pl.label = 'Fluorescence';
Pl.color = 'k';
Plot_X(Pl,F);

% plot calcium
i=i+1; h(2) = subplot(nrows,1,i);
Pl.label = 'Calcium';
Pl.color = Pl.gray;
Plot_X(Pl,C);

% plot spike train
i=i+1; h(3) = subplot(nrows,1,i);
maxn=max(n(Pl.xlims(1):Pl.xlims(2)));
Plot_n(Pl,n);

% plot inferred spike trains
for r=1:q
    i=i+1; h(3+r) = subplot(nrows,1,i);
    Pl.label = I{r}.name;
    maxn=max(I{r}.n(Pl.xlims(1):Pl.xlims(2)));
    Plot_n_MAP(Pl,I{r}.n);
end

subplot(nrows,1,nrows)
set(gca,'XTick',Pl.XTicks,'XTickLabel',Pl.XTicks*Sim.dt,'FontSize',Pl.fs)
xlabel('Time (sec)','FontSize',Pl.fs)
linkaxes(h,'x')
% linkaxes([h(end-1), h(end)])

% print fig
wh=[7 5];   %width and height
set(fig,'PaperPosition',[0 11-wh(2) wh]);
print('-depsc','schem')