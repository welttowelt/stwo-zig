struct PolynomialEvalTask {
    uint coefficient_offset, coefficient_length, basis_offset, log_size, output_index;
};

struct PolynomialBasisTask {
    uint factor_offset, log_size, basis_offset, basis_length;
};

static_assert(sizeof(PolynomialEvalTask) == 5u * sizeof(uint), "PolynomialEvalTask ABI");
static_assert(sizeof(PolynomialBasisTask) == 4u * sizeof(uint), "PolynomialBasisTask ABI");
