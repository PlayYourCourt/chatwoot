/* global axios */
import ApiClient from './ApiClient';

class SequenceReportsAPI extends ApiClient {
  constructor() {
    super('sequence_reports', { accountScoped: true, apiVersion: 'v2' });
  }

  getSummary({ flow, since, until }) {
    return axios.get(`${this.url}/summary`, {
      params: { flow, since, until },
    });
  }

  getEnrollments(params) {
    return axios.get(`${this.url}/enrollments`, { params });
  }

  getAttempts(params) {
    return axios.get(`${this.url}/attempts`, { params });
  }

  getEnrollment(id) {
    return axios.get(`${this.url}/${id}/enrollment`);
  }
}

export default new SequenceReportsAPI();
