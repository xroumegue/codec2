% fsk_horus.txt
% David Rowe 10 Oct 2015
%
% Experimental near space balloon FSK demodulator
% Assume high SNR, but fades near end of mission can wipe out a few bits
% So low SNR perf not a huge issue
%
% [ ] processing buffers of 1 second
%     + 8000 samples input
%     + keep 30 second sliding window to extract packet from
%     + do fine timing on this
%     [X] estimate frequency of two tones
%         + this way we cope with variable shift and drift
%     [ ] estimate amplitudes and equalise, or limit
% [X] Eb/No point 8dB, 2% ish
% [X] fine timing and sample slips, +/- 1000ppm (0.1%) clock offset test
% [ ] bit flipping against CRC
% [ ] implement CRC
% [ ] frame sync
% [ ] compare to fldigi
% [ ] test over range of f1/f2, shifts (varying), timing offsets, clock offsets, Eb/No

1;

function states = fsk_horus_init()
  states.Ndft = 8192;
  Fs = states.Fs = 8000;
  N = states.N = Fs;             % processing buffer size, nice big window for f1,f2 estimation
  Rs = states.Rs = 50;
  Ts = states.Ts = Fs/Rs;
  states.nsym = N/Ts;
  Nmem = states.Nmem  = N+2*Ts;    % one symbol memory in down converted signals to allow for timing adj
  states.f1_dc = zeros(1,Nmem);
  states.f2_dc = zeros(1,Nmem);
  states.P = 8;                  % oversample rate out of filter
  states.nin = N;                % can be N +/- Ts/P = N +/- 40 samples to adjust for sample clock offsets
  states.verbose = 1;
  states.phi1 = 0;               % keep down converter osc phase continuous
  states.phi2 = 0;
endfunction


% test modulator function

function tx  = fsk_horus_mod(states, tx_bits)
    tx = zeros(states.Ts*length(tx_bits),1);
    tx_phase = 0;
    Ts = states.Ts;
    f1 = 1500; f2 = 1900;

    for i=1:length(tx_bits)
      for k=1:Ts
        if tx_bits(i) == 1
          tx_phase += 2*pi*f1/states.Fs;
        else
          tx_phase += 2*pi*f2/states.Fs;
        end
        tx_phase = tx_phase - floor(tx_phase/(2*pi))*2*pi;
        tx((i-1)*Ts+k) = 2.0*cos(tx_phase);
      end
    end

endfunction


% Given a buffer of nin input samples, returns nsym bits.
%
% Automagically estimates the frequency of the two tones, or
% looking at it another way, the frequency offset and shift
%
% nin is the number of input samples required by demodulator.  This is
% time varying.  It will nominally be N (8000), and occasionally N +/-
% Ts/P (8020 or 7980 for P=8).  This is how we compensate for differences between the
% remote tx sample clock and our sample clock.  This function always returns
% N/Ts (50) demodulated bits.  Variable number of input samples, constant number
% of output bits.

function [rx_bits states] = fsk_horus_demod(states, sf)
  N = states.N;
  Ndft = states.Ndft;
  Fs = states.Fs;
  Rs = states.Rs;
  Ts = states.Ts;
  nsym = states.nsym;
  P = states.P;
  nin = states.nin;
  verbose = states.verbose;
  Nmem = states.Nmem;

  assert(length(sf) == nin);

  % find tone frequency and amplitudes ---------------------------------------------

  h = hanning(nin);
  Sf = fft(sf .* h, Ndft);
  [m1 m1_index] = max(Sf(1:Ndft/2));

  % zero out region around max so we can find second highest peak

  Sf2 = Sf;
  st = m1_index - 100;
  if st < 1
    st = 1;
  end
  en = m1_index + 100;
  if en > Ndft/2
    en = Ndft/2;
  end
  Sf2(st:en) = 0;

  [m2 m2_index] = max(Sf2(1:Ndft/2));

  % f1 always the lower tone

  if m1_index < m2_index
    f1 = (m1_index-1)*Fs/Ndft;
    f2 = (m2_index-1)*Fs/Ndft;
    twist = 20*log10(m1/m2);
  else
    f1 = (m2_index-1)*Fs/Ndft;
    f2 = (m1_index-1)*Fs/Ndft;
    twist = 20*log10(m2/m1);
  end

  states.f1 = f1;
  states.f2 = f2;

  if verbose
    %printf("f1: %4.0f Hz f2: %4.0f Hz\n", f1, f2);
  end

  % down convert and filter at 4Rs ------------------------------

  % update filter (integrator) memory by shifting in nin samples
  
  nold = Nmem-nin; % number of old samples we retain

  f1_dc = states.f1_dc; 
  f1_dc(1:nold) = f1_dc(Nmem-nold+1:Nmem);
  f2_dc = states.f2_dc; 
  f2_dc(1:nold) = f2_dc(Nmem-nold+1:Nmem);

  % shift down to around DC, ensuring continuous phase from last frame

  phi1_vec = states.phi1 + (1:nin)*2*pi*f1/Fs;
  phi2_vec = states.phi2 + (1:nin)*2*pi*f2/Fs;

  f1_dc(nold+1:Nmem) = sf' .* exp(-j*phi1_vec);
  f2_dc(nold+1:Nmem) = sf' .* exp(-j*phi2_vec);

  states.phi1  = phi1_vec(nin);
  states.phi1 -= 2*pi*floor(states.phi1/(2*pi));
  states.phi2  = phi2_vec(nin);
  states.phi2 -= 2*pi*floor(states.phi2/(2*pi));

  % save filter (integrator) memory for next time

  states.f1_dc = f1_dc;
  states.f2_dc = f2_dc;

  % integrate over symbol period, which is effectively a LPF, removing
  % the -2Fc frequency image.  Can also be interpreted as an ideal
  % integrate and dump, non-coherent demod.  We run the integrator at
  % PRs (1/P symbol offsets) to get outputs at a range of different
  % fine timing offsets.  We calculate integrator output over nsym+1
  % symbols so we have extra samples for the fine timing re-sampler at either
  % end of the array.

  rx_bits = zeros(1, (nsym+1)*P);
  for i=1:(nsym+1)*P
    st = 1 + (i-1)*Ts/P;
    en = st+Ts-1;
    f1_int(i) = sum(f1_dc(st:en));
    f2_int(i) = sum(f2_dc(st:en));
  end
  states.f1_int = f1_int;
  states.f2_int = f2_int;

  % fine timing estimation -----------------------------------------------

  % Non linearity has a spectral line at Rs, with a phase
  % related to the fine timing offset.  See:
  %   http://www.rowetel.com/blog/?p=3573 
  % We have sampled the integrator output at Fs=P samples/symbol, so
  % lets do a single point DFT at w = 2*pi*f/Fs = 2*pi*Rs/(P*Rs)

  Np = length(f1_int);
  w = 2*pi*(Rs)/(P*Rs);
  x = ((abs(f1_int)-abs(f2_int)).^2) * exp(-j*w*(0:Np-1))';
  norm_rx_timing = angle(x)/(2*pi);
  rx_timing = norm_rx_timing*P;

  states.x = x;
  states.rx_timing = rx_timing;
  states.norm_rx_timing = norm_rx_timing;

  % work out how many input samples we need on the next call. The aim
  % is to keep angle(x) away from the -pi/pi (+/- 0.5 fine timing
  % offset) discontinuity.  The side effect is to track sample clock
  % offsets

  next_nin = N;
  if norm_rx_timing > 0.375
     next_nin += Ts/P;
  end
  if norm_rx_timing < -0.375;
     next_nin -= Ts/P;
  end
  states.nin = next_nin;

  % Re sample integrator outputs using fine timing estimate and linear interpolation

  low_sample = floor(rx_timing);
  fract = rx_timing - low_sample;
  high_sample = ceil(rx_timing);

  if verbose
    printf("rx_timing: %3.2f low_sample: %d high_sample: %d fract: %3.3f nin_next: %d\n", rx_timing, low_sample, high_sample, fract, next_nin);
  end

  f1_int_resample = zeros(1,nsym);
  f2_int_resample = zeros(1,nsym);
  rx_bits = zeros(1,nsym);
  for i=1:nsym
    st = i*P+1;
    f1_int_resample(i) = f1_int(st+low_sample)*(1-fract) + f1_int(st+high_sample)*fract;
    f2_int_resample(i) = f2_int(st+low_sample)*(1-fract) + f2_int(st+high_sample)*fract;
    %f1_int_resample(i) = f1_int(st+1);
    %f2_int_resample(i) = f2_int(st+1);
    rx_bits(i) = abs(f1_int_resample(i)) > abs(f2_int_resample(i));
  end

  states.f1_int_resample = f1_int_resample;
  states.f2_int_resample = f2_int_resample;

endfunction


% demo script --------------------------------------------------------

function run_sim
  frames = 100;
  EbNodB = 8;
  timing_offset = 0.3;
  test_frame_mode = 2;

  more off
  rand('state',1); 
  randn('state',1);
  states = fsk_horus_init();
  N = states.N;
  P = states.P;
  Rs = states.Rs;
  nsym = states.nsym;

  EbNo = 10^(EbNodB/10);
  variance = states.Fs/(states.Rs*EbNo);

  if test_frame_mode == 1
     % test frame of bits, which we repeat for convenience when BER testing
    test_frame = round(rand(1, states.nsym));
    tx_bits = [];
    for i=1:frames+1
      tx_bits = [tx_bits test_frame];
    end
  end
  if test_frame_mode == 2
    % random bits, just to make sure sync algs work on random data
    tx_bits = round(rand(1, states.nsym*(frames+1)));
  end
  if test_frame_mode == 3
    % ...10101... sequence
    tx_bits = zeros(1, states.nsym*(frames+1));
    tx_bits(1:2:length(tx_bits)) = 1;
  end

  tx = fsk_horus_mod(states, tx_bits);
  %tx = resample(tx, 1000, 1000);

  noise = sqrt(variance/2)*(randn(length(tx),1) + j*randn(length(tx),1));
  rx    = tx + noise;

  timing_offset_samples = round(timing_offset*states.Ts);
  st = 1 + timing_offset_samples;
  rx_bits_buf = zeros(1,2*nsym);
  Terrs = Tbits = 0;
  state = 0;
  x_log = [];
  norm_rx_timing_log = [];
  nerr_log = [];
  f1_int_resample_log = [];
  f2_int_resample_log = [];

  for f=1:frames

    % extract nin samples from input stream

    nin = states.nin;
    en = st + states.nin - 1;
    sf = rx(st:en);
    st += nin;

    % demodulate to stream of bits

    [rx_bits states] = fsk_horus_demod(states, sf);
    rx_bits_buf(1:nsym) = rx_bits_buf(nsym+1:2*nsym);
    rx_bits_buf(nsym+1:2*nsym) = rx_bits;
    norm_rx_timing_log = [norm_rx_timing_log states.norm_rx_timing];
    x_log = [x_log states.x];
    f1_int_resample_log = [f1_int_resample_log abs(states.f1_int_resample)];
    f2_int_resample_log = [f2_int_resample_log abs(states.f2_int_resample)];

    % frame sync based on min BER

    if test_frame_mode == 1
      nerrs_min = nsym;
      next_state = state;
      if state == 0
        for i=1:nsym
          error_positions = xor(rx_bits_buf(i:nsym+i-1), test_frame);
          nerrs = sum(error_positions);
          if nerrs < nerrs_min
            nerrs_min = nerrs;
            coarse_offset = i;
          end
        end
        if nerrs_min < 3
          next_state = 1;
          %printf("%d %d\n", coarse_offset, nerrs_min);
        end
      end

      if state == 1  
        error_positions = xor(rx_bits_buf(coarse_offset:coarse_offset+nsym-1), test_frame);
        nerrs = sum(error_positions);
        Terrs += nerrs;
        Tbits += nsym;
        err_log = [nerr_log nerrs];
      end

      state = next_state;
    end
  end

  if test_frame_mode == 1
    printf("frames: %d Tbits: %d Terrs: %d BER %3.2f\n", frames, Tbits, Terrs, Terrs/Tbits);
  end

  figure(1);
  plot(f1_int_resample_log,'+')
  hold on;
  plot(f2_int_resample_log,'g+')
  hold off;

  figure(2)
  clf
  m = max(abs(x_log));
  plot(x_log,'+')
  axis([-m m -m m])
  title('fine timing metric')

  figure(3)
  clf
  plot(norm_rx_timing_log);
  axis([1 frames -1 1])
  title('norm fine timing')
endfunction


function rx_bits_log = demod_file(filename)
  rx = load_raw(filename);
  more off
  rand('state',1); 
  randn('state',1);
  states = fsk_horus_init();
  N = states.N;
  P = states.P;
  Rs = states.Rs;
  nsym = states.nsym;

  frames = floor(length(rx)/N);
  st = 1;
  rx_bits_log = [];
  rx_timing_log = [];
  f1_int_resample_log = [];
  f2_int_resample_log = [];

  for f=1:frames

    % extract nin samples from input stream

    nin = states.nin;
    en = st + states.nin - 1;
    sf = rx(st:en);
    st += nin;

    % demodulate to stream of bits

    [rx_bits states] = fsk_horus_demod(states, sf);
    rx_bits_log = [rx_bits_log rx_bits];
    rx_timing_log = [rx_timing_log states.rx_timing];
    f1_int_resample_log = [f1_int_resample_log abs(states.f1_int_resample)];
    f2_int_resample_log = [f2_int_resample_log abs(states.f2_int_resample)];
  end

  figure(1);
  plot(f1_int_resample_log,'+')
  hold on;
  plot(f2_int_resample_log,'g+')
  hold off;

  figure(2)
  clf
  plot(rx_timing_log)
  axis([1 frames -1 1])
 
endfunction

run_sim
%rx_bits = demod_file("~/Desktop/vk5arg-3.wav");


% [X] fixed test frame
% [X] frame sync on that
% [X] measure BER, and bits decoded
% [X] test with sample clock slip
% [X] test at Eb/No point
% [ ] try to match bits with real data
% [ ] look for UW