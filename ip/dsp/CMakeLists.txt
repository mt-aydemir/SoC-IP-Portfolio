#============================================================================
# ip/dsp - fixed-point signal processing
#
# Filters and transforms for a digital radio front end: a CIC decimator to
# take the rate down, FIR and IIR filters to shape the band, and an FFT.
# Every block is bit-exact against a reference model.
#============================================================================
add_ip_category(dsp
  fir
  cic
  iir
  fft
)
